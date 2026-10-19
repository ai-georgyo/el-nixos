#!/usr/bin/env python3
"""late-bind: the builder of lateBind.wrap (docs/nix-native-design.md §2.9,
§11.3; lib/rocky/late-bind.nix).

    python3 -I late-bind.py bind   --plan F --elf-lib DIR --patchelf P --shebangs LIST
    (patchShebangs --host over the outputs named in LIST, by the Nix builder)
    python3 -I late-bind.py verify --plan F

F is the structured-attrs file of the bind derivation (key `rockyLateBind`,
output paths under `outputs`, the raw outputs' reference graph under
`rawGraph`) or, for unit tests, a plain JSON file with the same keys at top
level plus `bound` = {output: path} and `rawGraph`.

Plan keys:
  storeDir       "/nix/store"
  late           [output]               the lateBind outputs L
  lstar          [output]               L* = L + declared referrers (the bound outputs)
  referrers      {late: [output]}       declared referrers per late output (globs expanded)
  skip           [output]               raw outputs outside L* and the check (debug, logs)
  raw            {output: path}         every raw output except skip
  binds          {output: {hostPath: "d1:d2", libs: [{name, dirs: [dir]}]}}
  summaryOutput  output name or null     extra output receiving the summary
  systemLibDirs  [dir]                  if non-empty: every DT_NEEDED of an ELF in an
                                        output with libs must resolve (RUNPATH, these, libs)

bind:
  1. names: raw and bound store names are equal, so every path has the same length
  2. referrers: every raw output (not skip) that reaches a late output through the
     raw outputs' registered references must be in L* (late-referrer-missing)
  3. copy raw.<o> -> $o for o in L*:
       symlinks         raw L* hashes -> bound hashes in the target
       ELF, ar          a raw L* hash outside the DT_RUNPATH/DT_RPATH string is
                        refused (late-elf-ref / late-archive-ref): ELF contents are
                        never rewritten (store-by-pieces, design §0.2 #1)
       compressed       gzip/xz/bzip2 members holding a raw L* hash are refused
                        (late-compressed-ref); nix-support/hidden-references naming a
                        raw L* output too (late-hidden-ref: pieced or nested content)
       anything else    raw L* hashes -> bound hashes (equal length)
  4. RUNPATH: raw L* entries -> bound; for outputs with libs, every DT_NEEDED not
     found through the old RUNPATH (or systemLibDirs) is looked up in the libs'
     dirs and the dir appended; patchelf --set-rpath when it changed. A lib that
     resolves nothing in its output is an error (late-lib-unused).
  5. writes LIST: "<output>\\t<hostPath>\\t<bound dir>" for outputs with interpreters
verify (after patchShebangs):
  * no raw L* hash in any bound file or symlink target (late-raw-left)
  * symlinks that resolved in raw still resolve (late-symlink-dangling)
  * late outputs: no FHS shebang other than #!/bin/sh and
    #!/usr/bin/env (runtime FHS, design §1.4) in an executable (late-shebang-unbound)
  * writes $o/nix-support/rocky-late-bind.json (what changed; no store paths),
    and the summary into the output named by `summaryOutput` (if any)
Exit status: 0 ok, 1 errors (listed on stderr), 2 plan/tool error."""
import argparse
import bz2
import collections
import gzip
import json
import lzma
import os
import re
import stat
import subprocess
import sys

RUNTIME_FHS_INTERPRETERS = ("/bin/sh", "/usr/bin/env")
MAX_INFLATE = 1 << 30
STATE = "late-bind-state.json"


class PlanError(Exception):
    pass


class Report:
    def __init__(self):
        self.errors, self.infos = [], []

    def error(self, code, msg):
        self.errors.append((code, msg))
        print("late-bind: error [%s] %s" % (code, msg), file=sys.stderr)

    def info(self, code, msg):
        self.infos.append((code, msg))
        print("late-bind: %s: %s" % (code, msg), file=sys.stderr)


def load_plan(path):
    with open(path) as f:
        d = json.load(f)
    if "rockyLateBind" in d:
        plan, bound = d["rockyLateBind"], d.get("outputs", {})
    else:
        plan, bound = d, d.get("bound", {})
    for k in ("storeDir", "late", "lstar", "raw"):
        if k not in plan:
            raise PlanError("plan has no `%s`" % k)
    plan.setdefault("referrers", {})
    plan.setdefault("skip", [])
    plan.setdefault("binds", {})
    plan.setdefault("systemLibDirs", [])
    plan["bound"] = {o: bound[o] for o in plan["lstar"] if o in bound}
    so = plan.get("summaryOutput")
    plan["summaryPath"] = bound.get(so) if so else None
    if so and not plan["summaryPath"]:
        raise PlanError("summaryOutput %s has no path" % so)
    missing = [o for o in plan["lstar"] if o not in plan["bound"] or o not in plan["raw"]]
    if missing:
        raise PlanError("L* outputs without a raw or bound path: %s" % " ".join(missing))
    plan["graph"] = d.get("rawGraph")
    if plan["graph"] is None:
        raise PlanError("no `rawGraph` (exportReferencesGraph of the raw outputs)")
    return plan


def hash_of(store, path):
    if not path.startswith(store + "/"):
        raise PlanError("%s is not in %s" % (path, store))
    return os.path.basename(path)[:32]


def walk(root):
    """(rel, path) of every entry below root, directories first, sorted"""
    out = []
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for n in sorted(dns + fns):
            p = os.path.join(dp, n)
            out.append((os.path.relpath(p, root), p))
    return out


class Ctx:
    def __init__(self, plan, rep):
        self.plan, self.rep = plan, rep
        st = plan["storeDir"]
        self.store = st
        self.lstar = list(plan["lstar"])
        self.late = set(plan["late"])
        self.raw, self.bound = plan["raw"], plan["bound"]
        self.rawh = {o: hash_of(st, self.raw[o]) for o in self.lstar}
        self.boundh = {o: hash_of(st, self.bound[o]) for o in self.lstar}
        self.owner = {self.rawh[o].encode(): o for o in self.lstar}
        self.subst = {self.rawh[o].encode(): self.boundh[o].encode() for o in self.lstar}
        self.rx = re.compile(b"|".join(re.escape(h) for h in sorted(self.subst)))

    def rewrite(self, data):
        return self.rx.sub(lambda m: self.subst[m.group(0)], data)

    def found(self, data):
        """{output: first offset} of raw L* hashes in data"""
        r = {}
        for m in self.rx.finditer(data):
            r.setdefault(self.owner[m.group(0)], m.start())
        return r

    def kind(self, o):
        return "late output" if o in self.late else "referrer"


# ---------------------------------------------------------------- bind

def check_names(ctx):
    for o in ctx.lstar:
        a, b = os.path.basename(ctx.raw[o]), os.path.basename(ctx.bound[o])
        if a[33:] != b[33:] or len(a) != len(b) or len(ctx.rawh[o]) != 32 or len(ctx.boundh[o]) != 32:
            ctx.rep.error("late-name", "%s: raw store name %s and bound %s differ (rewriting needs equal names)"
                          % (o, a, b))


def check_referrers(ctx):
    """every raw output reaching a late output must be in L* (transitive)"""
    plan, rep = ctx.plan, ctx.rep
    refs = {e["path"]: set(e.get("references", [])) for e in plan["graph"]}
    name_of = {p: o for o, p in plan["raw"].items()}
    skip = set(plan["skip"])
    for o, p in sorted(plan["raw"].items()):
        if p not in refs:
            rep.error("late-graph", "raw output %s (%s) is not in the reference graph" % (o, p))
    pred = collections.defaultdict(set)
    for o, p in plan["raw"].items():
        if o in skip:
            continue
        for r in refs.get(p, ()):
            x = name_of.get(r)
            if x is not None and x != o and x not in skip:
                pred[x].add(o)
    lstar = set(ctx.lstar)
    summary = {}
    for l in sorted(ctx.late):
        parent, todo = {l: None}, [l]
        while todo:
            v = todo.pop()
            for w in sorted(pred.get(v, ())):
                if w not in parent:
                    parent[w] = v
                    todo.append(w)
        reach = set(parent) - {l}
        summary[l] = sorted(reach)
        for y in sorted(reach - lstar):
            chain, v = [y], parent[y]
            while v is not None:
                chain.append(v)
                v = parent[v]
            rep.error("late-referrer-missing", "%s reaches late output %s (%s) but is not a declared referrer"
                      " (referrers.%s): it would keep the raw outputs in its closure"
                      % (y, l, " -> ".join(chain), l))
        for y in plan["referrers"].get(l, []):
            if y not in reach:
                rep.info("late-referrer-unused", "referrers.%s: %s references no raw L* output; bound anyway" % (l, y))
    return summary


def read_limited(opener, data):
    import io
    with opener(io.BytesIO(data)) as f:
        out = f.read(MAX_INFLATE + 1)
    if len(out) > MAX_INFLATE:
        raise ValueError("inflates beyond %d bytes" % MAX_INFLATE)
    return out


def decompress(data):
    """-> (format, bytes) for gzip/xz/bzip2 (all members), else (None, None);
    (format, None) when undecodable"""
    if data[:2] == b"\x1f\x8b":
        fmt, opener = "gzip", lambda f: gzip.GzipFile(fileobj=f)
    elif data[:6] == b"\xfd7zXZ\x00":
        fmt, opener = "xz", lambda f: lzma.LZMAFile(f)
    elif data[:3] == b"BZh":
        fmt, opener = "bzip2", lambda f: bz2.BZ2File(f)
    else:
        return None, None
    try:
        return fmt, read_limited(opener, data)
    except (OSError, EOFError, ValueError, lzma.LZMAError):
        return fmt, None


def expand_origin(entry, filedir):
    for tok in ("$ORIGIN", "${ORIGIN}"):
        entry = entry.replace(tok, filedir)
    return entry


def bind_output(ctx, o, elfmod, patchelf, records):
    rep, plan = ctx.rep, ctx.plan
    src, dst = ctx.raw[o], ctx.bound[o]
    rec = records.setdefault(o, {"text": [], "symlinks": [], "runpath": [], "shebangs": []})
    b = plan["binds"].get(o, {})
    libs = b.get("libs", [])
    used = {l["name"]: False for l in libs}
    sysdirs = plan["systemLibDirs"]
    if os.path.exists(dst) and os.listdir(dst):
        raise PlanError("%s: bound output %s is not empty" % (o, dst))
    os.makedirs(dst, exist_ok=True)
    os.chmod(dst, 0o755)
    hidden = os.path.join(src, "nix-support", "hidden-references")
    if os.path.isfile(hidden):
        with open(hidden, "rb") as f:
            for x in ctx.found(f.read()):
                rep.error("late-hidden-ref", "%s: nix-support/hidden-references names raw %s %s: that reference sits"
                          " in pieced or compressed content, which cannot be rebound" % (o, ctx.kind(x), x))
    patches = []
    for rel, p in walk(src):
        q = os.path.join(dst, rel)
        st = os.lstat(p)
        if stat.S_ISDIR(st.st_mode):
            os.mkdir(q)
            os.chmod(q, 0o755)
        elif stat.S_ISLNK(st.st_mode):
            t = os.readlink(p)
            nt = ctx.rewrite(t.encode("utf-8", "surrogateescape")).decode("utf-8", "surrogateescape")
            os.symlink(nt, q)
            if nt != t:
                rec["symlinks"].append(rel)
        elif stat.S_ISREG(st.st_mode):
            with open(p, "rb") as f:
                data = f.read()
            new = data
            if data[:4] == b"\x7fELF":
                ef = elfmod.parse(data)
                spans = ef.rpath_spans if ef else []
                for x, off in sorted(ctx.found(data).items()):
                    offs = [m.start() for m in ctx.rx.finditer(data) if ctx.owner[m.group(0)] == x]
                    bad = [i for i in offs if not any(a <= i < e for a, e in spans)]
                    if bad:
                        rep.error("late-elf-ref", "%s/%s: ELF content references raw %s %s at offset %#x (only"
                                  " symlinks, text and RUNPATH are rebound; ELF contents never)"
                                  % (o, rel, ctx.kind(x), x, bad[0]))
                if ef and ef.dynamic:
                    patches.append((rel, p, q, ef))
            elif data[:8] == b"!<arch>\n":
                for x, off in sorted(ctx.found(data).items()):
                    rep.error("late-archive-ref", "%s/%s: archive member references raw %s %s at offset %#x"
                              % (o, rel, ctx.kind(x), x, off))
            else:
                fmt, inner = decompress(data)
                if fmt:
                    if inner is None:
                        rep.info("late-compressed-unchecked", "%s/%s: %s data could not be decoded" % (o, rel, fmt))
                    else:
                        for x in sorted(ctx.found(inner)):
                            rep.error("late-compressed-ref", "%s/%s: %s member references raw %s %s"
                                      % (o, rel, fmt, ctx.kind(x), x))
                    for x in sorted(ctx.found(data)):
                        rep.error("late-compressed-ref", "%s/%s: compressed bytes contain the hash of raw %s"
                                  % (o, rel, x))
                else:
                    new = ctx.rewrite(data)
                    if new != data:
                        rec["text"].append(rel)
            with open(q, "wb") as f:
                f.write(new)
            os.chmod(q, (st.st_mode & 0o555) | 0o200)
        else:
            rep.error("late-file-type", "%s/%s: unsupported file type %o" % (o, rel, stat.S_IFMT(st.st_mode)))
    # RUNPATH
    for rel, p, q, ef in patches:
        old = ef.runpath if ef.runpath is not None else ef.rpath
        entries = [e for e in old.split(":")] if old else []
        new = [ctx.rewrite(e.encode("utf-8", "surrogateescape")).decode("utf-8", "surrogateescape") for e in entries]
        added = []
        if libs:
            fdir = os.path.dirname(p)
            for so in ef.needed:
                if any(os.path.exists(os.path.join(expand_origin(e, fdir), so)) for e in entries if e):
                    continue
                if any(os.path.exists(os.path.join(d, so)) for d in sysdirs):
                    continue
                hit = None
                for l in libs:
                    for d in l["dirs"]:
                        if os.path.exists(os.path.join(d, so)):
                            hit = (l["name"], d)
                            break
                    if hit:
                        break
                if hit:
                    used[hit[0]] = True
                    if hit[1] not in new:
                        new.append(hit[1])
                        added.append(os.path.basename(hit[1].rstrip("/")) if not hit[1].startswith(ctx.store + "/")
                                     else hit[1][len(ctx.store) + 34:])
                elif sysdirs:
                    rep.error("late-needed-unresolved", "%s/%s: DT_NEEDED %s found neither through RUNPATH, the"
                              " system dirs nor the bound libs" % (o, rel, so))
                else:
                    rep.info("late-needed-loader", "%s/%s: DT_NEEDED %s left to the loader's system dirs" % (o, rel, so))
        if new != entries:
            r = subprocess.run([patchelf, "--set-rpath", ":".join(new), q], capture_output=True, text=True)
            if r.returncode != 0:
                rep.error("late-patchelf", "%s/%s: patchelf --set-rpath failed: %s" % (o, rel, r.stderr.strip()))
            rec["runpath"].append({"file": rel, "added": added, "rebound": any(a != b for a, b in zip(entries, new))})
    for n, u in sorted(used.items()):
        if not u:
            rep.error("late-lib-unused", "binds.%s.libs: %s resolves no DT_NEEDED of %s (wrong library, or nothing"
                      " left to bind)" % (o, n, o))


def cmd_bind(args):
    plan = load_plan(args.plan)
    rep = Report()
    ctx = Ctx(plan, rep)
    check_names(ctx)
    if rep.errors:
        return 1
    reach = check_referrers(ctx)
    sys.path.insert(0, os.path.realpath(args.elf_lib))
    from rocky_partition import elf as elfmod  # noqa: E402
    records = {}
    for o in ctx.lstar:
        bind_output(ctx, o, elfmod, args.patchelf, records)
    with open(args.shebangs, "w") as f:
        for o in ctx.lstar:
            hp = plan["binds"].get(o, {}).get("hostPath", "")
            if hp:
                f.write("%s\t%s\t%s\n" % (o, hp, ctx.bound[o]))
    with open(args.state, "w") as f:
        json.dump({"records": records, "reach": reach}, f)
    print("late-bind: bound %d outputs (late: %s); %d errors" % (len(ctx.lstar), " ".join(sorted(ctx.late)),
                                                               len(rep.errors)), file=sys.stderr)
    return 1 if rep.errors else 0


# ---------------------------------------------------------------- verify

def shebang(data):
    if data[:2] != b"#!":
        return None
    line = data[2:].split(b"\n", 1)[0].decode("utf-8", "surrogateescape").strip()
    return line.split()[0] if line.split() else ""


def cmd_verify(args):
    plan = load_plan(args.plan)
    rep = Report()
    ctx = Ctx(plan, rep)
    try:
        with open(args.state) as f:
            state = json.load(f)
    except OSError:
        state = {"records": {}, "reach": {}}
    for o in ctx.lstar:
        src, dst = ctx.raw[o], ctx.bound[o]
        rec = state["records"].setdefault(o, {"text": [], "symlinks": [], "runpath": [], "shebangs": []})
        interp = o in ctx.late  # late outputs must leave no FHS shebang, interpreters given or not
        for rel, q in walk(dst):
            st = os.lstat(q)
            p = os.path.join(src, rel)
            if stat.S_ISLNK(st.st_mode):
                t = os.readlink(q)
                for x in ctx.found(t.encode("utf-8", "surrogateescape")):
                    rep.error("late-raw-left", "%s/%s: symlink target still names raw %s" % (o, rel, x))
                if os.path.exists(p) and not os.path.exists(q):
                    rep.error("late-symlink-dangling", "%s/%s -> %s: resolved in raw, dangles bound" % (o, rel, t))
            elif stat.S_ISREG(st.st_mode):
                with open(q, "rb") as f:
                    data = f.read()
                for x, off in sorted(ctx.found(data).items()):
                    rep.error("late-raw-left", "%s/%s: still references raw %s %s at offset %#x"
                              % (o, rel, ctx.kind(x), x, off))
                sb = shebang(data)
                if sb is None or not (st.st_mode & 0o100):
                    continue
                try:
                    with open(p, "rb") as f:
                        before = shebang(f.read(4096))
                except OSError:
                    before = None
                if before != sb:
                    rec["shebangs"].append({"file": rel, "interpreter": os.path.basename(sb), "was": before})
                if interp and not sb.startswith(ctx.store + "/") and (sb or "/bin/sh") not in RUNTIME_FHS_INTERPRETERS:
                    rep.error("late-shebang-unbound", "%s/%s: #!%s: no bound interpreter provides %s"
                              % (o, rel, sb, os.path.basename(sb)))
        ns = os.path.join(dst, "nix-support")
        os.makedirs(ns, exist_ok=True)
        doc = {"output": o, "late": o in ctx.late, "rebound": rec}
        if o in ctx.late:
            doc["referrers"] = state["reach"].get(o, [])
        with open(os.path.join(ns, "rocky-late-bind.json"), "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
            f.write("\n")
    if plan["summaryPath"]:
        ns = os.path.join(plan["summaryPath"], "nix-support")
        os.makedirs(ns, exist_ok=True)
        doc = {"late": sorted(ctx.late), "lstar": ctx.lstar, "referrers": state["reach"],
               "rebound": state["records"], "errors": [c for c, m in rep.errors]}
        with open(os.path.join(ns, "rocky-late-bind.json"), "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
            f.write("\n")
    print("late-bind: verified %d outputs; %d errors" % (len(ctx.lstar), len(rep.errors)), file=sys.stderr)
    return 1 if rep.errors else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="late-bind")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("bind")
    b.add_argument("--plan", required=True)
    b.add_argument("--elf-lib", required=True, help="directory holding the rocky_partition package (elf.py)")
    b.add_argument("--patchelf", default="patchelf")
    b.add_argument("--shebangs", required=True)
    b.add_argument("--state", default=STATE)
    v = sub.add_parser("verify")
    v.add_argument("--plan", required=True)
    v.add_argument("--state", default=STATE)
    a = ap.parse_args(argv)
    try:
        return cmd_bind(a) if a.cmd == "bind" else cmd_verify(a)
    except PlanError as e:
        print("late-bind: plan error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
