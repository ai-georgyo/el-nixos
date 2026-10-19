#!/usr/bin/env python3
"""nn-parity: parity of a relocated (Nix-native, one output per subpackage)
package against the official Rocky RPMs.  Design §7.4-§7.6, WP9.

Usage:
  nn-parity.py files   --plan PLAN [--allow FILE]... --out DIR
  nn-parity.py content --plan PLAN [--allow FILE]... --out DIR
  nn-parity.py abi     --plan PLAN [--allow FILE]... --out DIR
  nn-parity.py closure --plan PLAN --graphs DIR [--allow FILE]... --out DIR
  nn-parity.py runtime --ours DIR --official DIR --plan PLAN [--allow FILE]... --out DIR
  nn-parity.py selftest
  nn-parity.py meta-from-rpm --rpm RPM --output-name O --out FILE   (test fixtures)

PLAN (JSON, written by lib/rocky/nn-checks/glibc.nix):
  { "name": "glibc",
    "outputs":    { "<output>": "/nix/store/...", ... },    every output
    "rpmOutputs": { "<rpm name>": "<output>", ... },         every subpackage
    "official":   { "<rpm name>": "/nix/store/...rpm", ... } shipped subpackages
    "extraAllowed": [ "/nix/store/..." ],                    closure: allowed
                                                             non-sibling paths
    "map":        { "/nix/store/...": "<label>" } }          runtime: extra
                                                             path labels
The relocated layout (design §2.2): official /usr/x <-> <output>/x,
/etc/x <-> <output>/etc/x (also /var, /run), usrmerge spellings /lib64/x,
/bin/x ... <-> <output>/lib64/x ...; .build-id links, directories and
%ghost files are ignored.  Output store paths in our files are mapped to
/usr before text/ELF comparison ("path map").

Checks (difference ids; allowlists use rpm-parity's format, tools/parity/
nn-*.json, with an optional "effect" naming the cause, e.g. P1):
  files    per shipped subpackage: files.missing / files.misplaced (in
           another output) / files.only-ours (in the output, claimed by no
           subpackage mapped to it) / files.type / files.exec (executable
           bit; the store has no other mode bits) / files.linkto (targets
           resolved in the rpm namespace, $X/rel <-> /usr/rel); and the
           partitioner's metadata (nix-support/rpm/<subpkg>.json, from the
           transient headers) vs the official header: meta.mode/flags/user/
           group/caps/linkto/ghost per file, meta.<deps>:+x/-x for
           provides/requires/conflicts/obsoletes/recommends/suggests/
           supplements/enhances, meta.absent
  content  regular files: equal bytes (header digest), else text equal after
           the path map (content.text), else ELF semantics (elf.*: the
           rpm-parity facts; loaded sections classified identical /
           path-map / displacement (objdump, RIP-relative displacements and
           addresses masked) / layout (same size, address-carrying section of
           a file whose layout moved) / strings (same string multiset after
           the map); relocatable objects: relocations with addends into
           path-mapped string sections shifted back; symbol sizes of
           path-carrying objects compared after the map), static archives
           (ar.*), else content.bytes
  abi      tools/abi-compare.py over per-subpackage views of our ELF/ar/
           header files at their FHS paths, every readelf/nm output passed
           through the path map; dynsym size changes of objects that are
           equal after the map (relocated default paths) are classified, not
           reported
  closure  every output's closure (exportReferencesGraph files in --graphs,
           one per output, named graph-<output>) must be inside the siblings and
           extraAllowed (+ their closures); no output may reference debug or
           logs (closure.foreign, closure.debug-ref)
  runtime  two behaviour reports (lib/rocky/nn-checks, packages/glibc-nn-
           runtime): ### items compared after normalisation (output paths ->
           /usr, map labels, usrmerge spellings, addresses); per-locale files
           compared record by record

Exit status: 0 = PASS, 1 = FAIL (unexpected differences), 2 = error.
"""
import argparse
import difflib
import fnmatch
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
ALLOW_DIR = os.path.join(TOOL_DIR, "parity")
sys.path.insert(0, TOOL_DIR)  # -I drops the script dir from sys.path


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOL_DIR, file))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


rp = _load("rpm_parity", "rpm-parity.py")   # Rpm, parse_elf, parse_ar, Rules, render_dep, ...
from rpm_purity import ToolError, cpio_entries, close_all  # noqa: E402

STORE_PATH_RE = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s\0\"':;,()<>]*")
STORE_PATH_RE_B = re.compile(rb"/nix/store/[0-9a-z]{32}-[^/\s\0\"':;,()<>]*")
BUILD_ID_RE = re.compile(r"^/usr/lib(/debug)?/\.build-id(/|$)")
FHS_TOP = ("etc", "var", "run", "boot", "opt", "srv")
USRMERGE = ("bin", "sbin", "lib", "lib64")
S_IFMT, S_IFREG, S_IFLNK, S_IFDIR = 0o170000, 0o100000, 0o120000, 0o040000
SHF_ALLOC, SHF_EXECINSTR, SHF_MERGE, SHF_STRINGS = 0x2, 0x4, 0x10, 0x20


# --------------------------------------------------------------------------- paths
def fhs2rel(path):
    """official (rpm namespace) path -> output-relative path"""
    if path.startswith("/usr/"):
        return path[5:]
    return path.lstrip("/")


def rel2fhs(rel):
    top = rel.split("/", 1)[0]
    if top in FHS_TOP:
        return "/" + rel
    return "/usr/" + rel


def usrmerge(p):
    """/lib64/x -> /usr/lib64/x (Rocky's top-level links); a no-op elsewhere"""
    for t in USRMERGE:
        if p == "/" + t or p.startswith("/" + t + "/"):
            return "/usr" + p
    return p


# usrmerge spellings inside text: a path token starting with /lib64, /lib,
# /libx32, /bin, /sbin (not preceded by a path character, nor by the '>' of
# a map label: "<libgcc>/lib64/" is the label's own dir, not FHS /lib64)
USRMERGE_TEXT = re.compile(r"(?<![\w./@+>-])/(lib64|libx32|lib|bin|sbin)(?=[/\s\"'():;,]|$)", re.M)
USRMERGE_DATA = re.compile(rb"(?<![\w./@+>-])/(lib64|libx32|lib|bin|sbin)(?=[/\s\"'():;,\0]|$)")


def usrmerge_text(s):
    return USRMERGE_TEXT.sub(r"/usr/\1", s)


def usrmerge_data(b):
    return USRMERGE_DATA.sub(rb"/usr/\1", b)


class PathMap:
    """output store paths <-> /usr; labels for other known store paths"""

    def __init__(self, outputs, labels=None):
        self.outputs = dict(outputs)
        self.by_path = {p: o for o, p in self.outputs.items()}
        self.labels = dict(labels or {})
        alts = sorted(self.by_path, key=len, reverse=True)
        self.re_s = re.compile("|".join(re.escape(p) for p in alts)) if alts else None
        self.re_b = re.compile(b"|".join(re.escape(p.encode()) for p in alts)) if alts else None
        lab = sorted(self.labels, key=len, reverse=True)
        self.lab_s = re.compile("|".join(re.escape(p) for p in lab)) if lab else None

    def text(self, s):
        if s is None:
            return None
        if self.re_s is not None:
            s = self.re_s.sub("/usr", s)
        if self.lab_s is not None:
            s = self.lab_s.sub(lambda m: self.labels[m.group(0)], s)
        return s

    def data(self, b):
        """bytes with every output path replaced by /usr, and the replaced
        spans [(start, end)] in the original"""
        if self.re_b is None:
            return b, []
        spans = [(m.start(), m.end()) for m in self.re_b.finditer(b)]
        return (self.re_b.sub(b"/usr", b) if spans else b), spans

    def split(self, path):
        """absolute store path -> (output, rel) or (None, None)"""
        for p, o in self.by_path.items():
            if path == p:
                return o, ""
            if path.startswith(p + "/"):
                return o, path[len(p) + 1:]
        return None, None


def walk_output(root):
    """rel -> ('reg', mode) | ('lnk', target) for every non-directory below
    root, nix-support/ excluded"""
    out = {}
    for d, dirs, files in os.walk(root):
        reld = os.path.relpath(d, root)
        if reld == ".":
            dirs[:] = [x for x in dirs if x != "nix-support"]
            reld = ""
        for x in dirs + files:
            p = os.path.join(d, x)
            rel = (reld + "/" + x) if reld else x
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("lnk", os.readlink(p))
                if x in dirs:
                    dirs.remove(x)  # (os.walk does not follow it anyway)
            elif stat.S_ISREG(st.st_mode):
                out[rel] = ("reg", st.st_mode & 0o7777)
    return out


def sha256_file(path, algo="sha256"):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_plan(path):
    with open(path) as f:
        plan = json.load(f)
    for k in ("outputs", "rpmOutputs"):
        if k not in plan:
            raise ToolError("plan %s: missing %s" % (path, k))
    return plan


# --------------------------------------------------------------------------- results
class Result:
    """differences of one check, matched against rpm-parity Rules"""

    def __init__(self, check, rules):
        self.check, self.rules = check, rules
        self.diffs, self.stats, self.info = [], {}, []
        self.per_pkg = {}

    def diff(self, key, did, ours, official, detail=None):
        r = self.rules.match_allow(key, did, ours, official)
        d = {"package": key, "id": did, "ours": ours, "official": official, "allowed": r is not None}
        if r is not None:
            d["reason"] = r["reason"]
            d["effect"] = r.get("effect") or os.path.splitext(r["_src"])[0]
        if detail is not None:
            d["detail"] = detail
        self.diffs.append(d)
        self.per_pkg.setdefault(key, []).append(d)
        return d

    def value(self, key, did, ours, official, detail=None):
        if ours != official:
            self.diff(key, did, ours, official, detail)
            return False
        return True

    def setdiff(self, key, did, ours, official):
        so, sf = set(ours), set(official)
        for x in sorted(so - sf):
            self.diff(key, "%s:+%s" % (did, x), x, None)
        for x in sorted(sf - so):
            self.diff(key, "%s:-%s" % (did, x), None, x)
        return so == sf

    def count(self, k, n=1):
        self.stats[k] = self.stats.get(k, 0) + n

    def finish(self, out, name, fail_on_unused=False, extra=None, require=None):
        unexpected = [d for d in self.diffs if not d["allowed"]]
        unused = [r for r in self.rules.allow if not r["_hits"] and not r.get("optional")]
        problems = list(require or [])
        status = "FAIL" if unexpected or problems or (fail_on_unused and unused) else "PASS"
        effects = {}
        for d in self.diffs:
            if d["allowed"]:
                e = d.get("effect") or "-"
                effects[e] = effects.get(e, 0) + 1
        rep = {"check": self.check, "name": name, "status": status, "stats": self.stats,
               "unexpected": len(unexpected), "allowed": len(self.diffs) - len(unexpected),
               "allowedByEffect": effects, "problems": problems,
               "unusedRules": [r["id"] for r in unused], "differences": self.diffs, "info": self.info}
        if extra:
            rep.update(extra)
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "report.json"), "w") as f:
            json.dump(rep, f, indent=1, sort_keys=True, default=str)
        L = ["nn-parity %s %s: %s" % (self.check, name, status),
             "stats: " + json.dumps(self.stats, sort_keys=True),
             "differences: %d unexpected, %d allowed (%s); %d unused allowlist rule(s)" % (
                 len(unexpected), len(self.diffs) - len(unexpected),
                 ", ".join("%s %d" % kv for kv in sorted(effects.items())) or "-", len(unused))]
        L += ["PROBLEM: " + p for p in problems]
        if extra and extra.get("summary"):
            L += extra["summary"]
        L.append("")
        for d in sorted(self.diffs, key=lambda d: (d["allowed"], d["package"], d["id"])):
            L.append("%s %s: %s%s" % ("ALLOWED" if d["allowed"] else "UNEXPECTED", d["package"], d["id"],
                                      (" [%s] -- %s" % (d.get("effect") or "-", d["reason"])) if d["allowed"] else ""))
            if not d["allowed"]:
                L.append("    ours: %s" % short(d["ours"]))
                L.append("    official: %s" % short(d["official"]))
                det = d.get("detail")
                if isinstance(det, dict) and det.get("diff"):
                    L += ["    " + x for x in det["diff"][:80]]
                elif det is not None:
                    L.append("    detail: %s" % short(det, 600))
        for r in unused:
            L.append("UNUSED allowlist rule: %s" % r["id"])
        with open(os.path.join(out, "report.txt"), "w") as f:
            f.write("\n".join(L) + "\n")
        head = L[:4 + len(problems)] + (extra.get("summary", []) if extra else [])
        tail = [x for x in L if x.startswith(("UNEXPECTED", "UNUSED", "    "))]
        print("\n".join(head + tail[:400]), file=sys.stderr)
        if len(tail) > 400:
            print("... (%d more lines in report.txt)" % (len(tail) - 400), file=sys.stderr)
        return 0 if status == "PASS" else 1


def short(v, n=300):
    s = v if isinstance(v, str) else json.dumps(v, default=str)
    return s if len(s) <= n else s[:n] + "..."


def load_rules(paths, default=True):
    rules = rp.Rules()
    nd = os.path.join(ALLOW_DIR, "nn-default.json")
    if default and os.path.exists(nd):
        rules.load(nd, optional=True)
    for p in paths:
        rules.load(p)
    return rules


# --------------------------------------------------------------------------- official side
class Official:
    """one official RPM: header file table in the relocated namespace"""

    def __init__(self, path):
        self.rpm = rp.Rpm(path)
        self.key = self.rpm.key
        self.files = {}   # rel -> header entry (+ "path")
        self.ghosts = {}
        for p, fe in self.rpm.files.items():
            if BUILD_ID_RE.match(p):
                continue
            m = fe["mode"] & S_IFMT
            if m == S_IFDIR:
                continue
            fe = dict(fe, path=p)
            if fe["flags"] & 64:
                self.ghosts[fhs2rel(p)] = fe
                continue
            self.files[fhs2rel(p)] = fe

    def payload(self, want_groups):
        """{group_id: bytes} for the wanted hard-link groups (one pass)"""
        got = {}
        if not want_groups:
            return got
        raw, closers = self.rpm.payload_stream()
        try:
            for path, mode, size, rd in cpio_entries(raw):
                fe = self.rpm.files.get(path)
                if fe is None or (mode & S_IFMT) != S_IFREG or size == 0:
                    continue
                g = fe["group_id"]
                if g in want_groups and g not in got:
                    buf = bytearray()
                    while True:
                        c = rd(1 << 20)
                        if not c:
                            break
                        buf += c
                    got[g] = bytes(buf)
        finally:
            close_all(closers)
        return got


def official_target(path, linkto):
    t = linkto if linkto.startswith("/") else os.path.normpath(os.path.join(os.path.dirname(path), linkto))
    return usrmerge(t)


def our_target(pm, out_name, rel, target):
    """our symlink target -> canonical rpm-namespace path (or the raw target)"""
    if target.startswith("/nix/store/"):
        o, r = pm.split(target)
        if o is None:
            return target
        return usrmerge(rel2fhs(r)) if r else "/usr"
    if target.startswith("/"):
        return usrmerge(target)
    r = os.path.normpath(os.path.join(os.path.dirname(rel), target))
    if r.startswith(".."):
        # above the output: resolve against the store path of the output
        absd = os.path.normpath(os.path.join(pm.outputs[out_name], os.path.dirname(rel), target))
        o, r2 = pm.split(absd)
        return usrmerge(rel2fhs(r2)) if o is not None else absd
    return usrmerge(rel2fhs(r))


# --------------------------------------------------------------------------- files
DEPKINDS = ["provides", "requires", "conflicts", "obsoletes", "recommends", "suggests",
            "supplements", "enhances"]


def check_files(plan, rules, out):
    pm = PathMap(plan["outputs"])
    res = Result("files", rules)
    rpm_out = plan["rpmOutputs"]
    official = {n: Official(p) for n, p in sorted(plan["official"].items())}
    trees = {o: walk_output(p) for o, p in plan["outputs"].items() if os.path.isdir(p)}
    claimed = {o: set() for o in trees}
    stubs = {}
    for o, p in plan["outputs"].items():
        sf = os.path.join(p, "nix-support", "rocky-stubs")
        if os.path.exists(sf):
            with open(sf) as f:
                for line in f:
                    if line.strip():
                        stubs.setdefault(o, set()).add(line.split()[0])
    # where every rel lives (for misplaced files)
    where = {}
    for o, t in trees.items():
        for rel in t:
            where.setdefault(rel, []).append(o)
    matched, nrpm = 0, 0
    for name, off in official.items():
        nrpm += 1
        key = off.key
        o = rpm_out.get(name)
        if o is None or o not in trees:
            res.diff(key, "files.no-output", o, name)
            continue
        t = trees[o]
        res.count("official_files", len(off.files))
        for rel, fe in sorted(off.files.items()):
            fhs = fe["path"]
            claimed[o].add(rel)
            mine = t.get(rel)
            if mine is None:
                if rel in where:
                    res.diff(key, "files.misplaced:" + fhs, where[rel], o)
                else:
                    res.diff(key, "files.missing:" + fhs, None, rp.fmt_file(fe))
                continue
            otype = "lnk" if (fe["mode"] & S_IFMT) == S_IFLNK else "reg"
            if mine[0] != otype:
                res.diff(key, "files.type:" + fhs, mine[0], otype)
                continue
            if otype == "reg":
                res.count("regular")
                res.value(key, "files.exec:" + fhs, bool(mine[1] & 0o111), bool(fe["mode"] & 0o111))
            else:
                res.count("symlinks")
                a = our_target(pm, o, rel, mine[1])
                b = official_target(fhs, fe["linkto"])
                res.value(key, "files.linkto:" + fhs, a, b, detail={"raw": mine[1], "official": fe["linkto"]})
        check_meta(res, pm, plan, name, off, o)
        if not [d for d in res.per_pkg.get(key, []) if not d["allowed"]]:
            matched += 1
    # files in an output that no subpackage mapped to it claims
    unshipped = sorted(n for n in rpm_out if n not in official)
    for n in unshipped:
        o = rpm_out[n]
        meta = read_meta(plan, n, o)
        if meta is None:
            res.info.append("unshipped %s (%s): no metadata, its files cannot be told apart" % (n, o))
            continue
        for fe in meta.get("files", []):
            if fe.get("type") != "dir" and not fe.get("ghost") and o in claimed:
                claimed[o].add(fe["rel"])
    for o, t in sorted(trees.items()):
        if o in ("debug", "logs"):
            continue
        for rel in sorted(set(t) - claimed[o]):
            if rel in stubs.get(o, ()):
                res.count("stubs")
                continue
            res.diff("output:" + o, "files.only-ours:" + rel2fhs(rel), t[rel][0], None)
    res.stats["shipped_rpms"] = nrpm
    res.stats["shipped_rpms_matched"] = matched
    summary = ["shipped RPMs matched: %d/%d" % (matched, nrpm)]
    return res.finish(out, plan.get("name", "?"), extra={"summary": summary})


def read_meta(plan, name, o):
    p = os.path.join(plan["outputs"].get(o, "/nonexistent"), "nix-support", "rpm", name + ".json")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return json.load(f)


def check_meta(res, pm, plan, name, off, o):
    key = off.key
    meta = read_meta(plan, name, o)
    if meta is None:
        res.diff(key, "meta.absent", None, "nix-support/rpm/%s.json" % name)
        return
    res.count("metadata")
    mfiles = {}
    for fe in meta.get("files", []):
        if fe.get("type") == "dir" or BUILD_ID_RE.match(fe.get("path", "")):
            continue
        mfiles[fe["path"]] = fe
    ofiles = {fe["path"]: fe for fe in list(off.files.values()) + list(off.ghosts.values())}
    for p in sorted(set(mfiles) - set(ofiles)):
        res.diff(key, "meta.only-ours:" + p, mfiles[p].get("type"), None)
    for p in sorted(set(ofiles) - set(mfiles)):
        res.diff(key, "meta.only-official:" + p, None, rp.fmt_file(ofiles[p]))
    for p in sorted(set(mfiles) & set(ofiles)):
        a, b = mfiles[p], ofiles[p]
        res.value(key, "meta.mode:" + p, a.get("mode"), "%o" % b["mode"])
        res.value(key, "meta.flags:" + p, a.get("flags") or "-", rp.fmt_flags(b["flags"]))
        res.value(key, "meta.user:" + p, a.get("user"), b["user"])
        res.value(key, "meta.group:" + p, a.get("group"), b["group"])
        res.value(key, "meta.caps:" + p, a.get("caps") or "", b["caps"] or "")
        if (b["mode"] & S_IFMT) == S_IFLNK:
            res.value(key, "meta.linkto:" + p, pm.text(a.get("linkto") or ""), b["linkto"])
        elif (b["mode"] & S_IFMT) == S_IFREG and not b["flags"] & 64 and a.get("digest") \
                and b["digest"] and off.rpm.digestalgo == "sha256":
            res.count("meta_digest_compared")
            if a["digest"] != b["digest"]:
                res.count("meta_digest_differs")   # content is the content check's job
    for kind in DEPKINDS:
        ours = [rp.render_dep(pm.text(d["name"]), d.get("version") or "", d.get("flags") or 0)
                for d in meta.get(kind, [])]
        res.setdiff(key, "meta." + kind, ours, rp.deps(off.rpm, kind))


# --------------------------------------------------------------------------- ELF helpers
class Elf:
    """sections (with bytes) and symbols (with values) of one ELF image"""

    def __init__(self, d):
        self.d = d
        self.e = "<" if d[5] == 1 else ">"
        self.is64 = d[4] == 2
        e = self.e
        if self.is64:
            (self.etype, _m, _v, _en, phoff, shoff, _fl, _eh, phes, phn, shes, shn,
             shstrndx) = struct.unpack_from(e + "HHIQQQIHHHHHH", d, 16)
        else:
            (self.etype, _m, _v, _en, phoff, shoff, _fl, _eh, phes, phn, shes, shn,
             shstrndx) = struct.unpack_from(e + "HHIIIIIHHHHHH", d, 16)
        self.sh = []
        for i in range(shn if shoff else 0):
            o = shoff + i * shes
            if self.is64:
                nm, st, sf, sa, so, ss, sl, si, sal, ses = struct.unpack_from(e + "IIQQQQIIQQ", d, o)
            else:
                nm, st, sf, sa, so, ss, sl, si, sal, ses = struct.unpack_from(e + "IIIIIIIIII", d, o)
            self.sh.append({"nm": nm, "type": st, "flags": sf, "addr": sa, "off": so, "size": ss,
                            "link": sl, "info": si, "align": sal, "entsize": ses, "name": ""})
        if self.sh and shstrndx < len(self.sh):
            stro = self.sh[shstrndx]["off"]
            for s in self.sh:
                s["name"] = rp._strz(d, stro + s["nm"])
        keys = rp._unique_names([s["name"] for s in self.sh])
        for s, k in zip(self.sh, keys):
            s["key"] = k
        self.by_key = {s["key"]: s for s in self.sh}

    def data(self, s):
        if s["type"] == 8:
            return b""
        return self.d[s["off"]:s["off"] + s["size"]]

    def symbols(self, s):
        e, d = self.e, self.d
        stro = self.sh[s["link"]]["off"] if s["link"] < len(self.sh) else None
        fmt = e + ("IBBHQQ" if self.is64 else "IIIBBH")
        ent = struct.calcsize(fmt)
        res = []
        for t in struct.iter_unpack(fmt, d[s["off"]:s["off"] + (s["size"] // ent) * ent]):
            if self.is64:
                nm, info, other, shndx, val, size = t
            else:
                nm, val, size, info, other, shndx = t
            res.append({"name": rp._strz(d, stro + nm) if stro is not None else "?", "type": info & 0xf,
                        "bind": info >> 4, "vis": other & 3, "shndx": shndx, "value": val, "size": size})
        return res

    def object_bytes(self, sym):
        """bytes of a defined symbol (value -> section offset)"""
        if not sym["shndx"] or sym["shndx"] >= len(self.sh):
            return None
        s = self.sh[sym["shndx"]]
        if s["type"] == 8:
            return None
        base = s["addr"] if self.etype != 1 else 0
        o = sym["value"] - base
        if o < 0 or o + sym["size"] > s["size"]:
            return None
        return self.d[s["off"] + o:s["off"] + o + sym["size"]]

    def relocs(self):
        """{target section key: [(offset, type, symbol | [section], addend, section index)]}"""
        out = {}
        for s in self.sh:
            if s["type"] not in (4, 9) or s["info"] >= len(self.sh) or not self.sh[s["info"]]["flags"] & SHF_ALLOC:
                continue
            syms = self.symbols(self.sh[s["link"]]) if s["link"] < len(self.sh) else []
            rela = s["type"] == 4
            fmt = self.e + (("QQq" if rela else "QQ") if self.is64 else ("IIi" if rela else "II"))
            ent = struct.calcsize(fmt)
            lst = []
            for t in struct.iter_unpack(fmt, self.d[s["off"]:s["off"] + (s["size"] // ent) * ent]):
                off, info = t[0], t[1]
                si, rt = (info >> 32, info & 0xffffffff) if self.is64 else (info >> 8, info & 0xff)
                tgt, tsec = "#%d" % si, None
                if si < len(syms):
                    sy = syms[si]
                    if sy["type"] == 3 and sy["shndx"] < len(self.sh):
                        tsec = sy["shndx"]
                        tgt = "[%s]" % self.sh[tsec]["key"]
                    else:
                        tgt = sy["name"]
                lst.append((off, rt, tgt, t[2] if rela else 0, tsec))
            out[self.sh[s["info"]]["key"]] = lst
        return out


def strings_of(b):
    return sorted(x for x in b.split(b"\0") if x)


def string_set(b):
    """NUL-separated chunks with usrmerge spellings canonicalised"""
    return {usrmerge_data(x) for x in b.split(b"\0") if x}


def strings_match(a, b):
    """every chunk of each side is a chunk of the other or a tail of one
    (ld tail-merges strings in SHF_MERGE|SHF_STRINGS sections)"""
    if a == b:
        return True

    def covered(xs, ys):
        tails = set()
        for y in ys:
            for i in range(len(y)):
                tails.add(y[i:])
        return all(x in tails for x in xs)
    return covered(a - b, b) and covered(b - a, a)


DISASM_ADDR = re.compile(r"^\s*[0-9a-f]+:\s*")
DISASM_RIP = re.compile(r"-?0x[0-9a-f]+(?=\(%rip\))")
DISASM_TARGET = re.compile(r"\b[0-9a-f]+ <[^>]*>")
DISASM_SYM = re.compile(r"<[^>]*>")
DISASM_COMMENT = re.compile(r"#.*$")


def disasm(path, section):
    p = subprocess.run(["objdump", "-d", "-w", "--no-show-raw-insn", "-j", section, path],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise ToolError("objdump failed on %s: %s" % (path, p.stderr.decode(errors="replace")[:300]))
    out = []
    started = False
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("Disassembly of section"):
            started = True
            continue
        if not started or not line.strip() or line.endswith(">:"):
            continue
        line = DISASM_ADDR.sub("", line)
        line = DISASM_COMMENT.sub("", line)
        line = DISASM_RIP.sub("D", line)
        line = DISASM_TARGET.sub("T", line)
        line = DISASM_SYM.sub("", line)
        out.append(line.rstrip())
    return out


LAYOUT_SECS = {".dynsym", ".rela.dyn", ".rela.plt", ".rel.dyn", ".rel.plt", ".relr.dyn", ".got", ".got.plt",
               ".data.rel.ro", ".dynamic", ".init_array", ".fini_array", ".preinit_array", ".eh_frame",
               ".eh_frame_hdr", ".data", ".tdata", ".gcc_except_table", ".sframe"}


class ElfCompare:
    """semantic comparison of one ELF file (or archive member), see the
    module docstring; every differing loaded section is either classified
    (counted in the stats) or reported"""

    def __init__(self, res, key, pm, workdir):
        self.res, self.key, self.pm, self.workdir = res, key, pm, workdir

    def compare(self, p, ours, off, ours_path=None):
        res, key, pm = self.res, self.key, self.pm
        fa, fb = rp.parse_elf(ours), rp.parse_elf(off)
        if "error" in fa or "error" in fb:
            res.diff(key, "elf.error:" + p, fa.get("error"), fb.get("error"))
            return
        for prop in ("class", "machine", "type", "soname", "needed", "gnu_hash", "sysv_hash", "bind_now", "pie",
                     "textrel", "relr", "execstack", "relro", "gnu_property", "abi_tag", "stapsdt",
                     "package_note", "comment"):
            res.value(key, "elf.%s:%s" % (prop, p), fa.get(prop), fb.get(prop))
        res.value(key, "elf.build_id:" + p, fa.get("build_id") is not None, fb.get("build_id") is not None)
        ia = usrmerge(pm.text(fa["interp"])) if fa.get("interp") else None
        ib = usrmerge(fb["interp"]) if fb.get("interp") else None
        res.value(key, "elf.interp:" + p, ia, ib, detail={"raw": fa.get("interp")})
        for prop in ("rpath", "runpath"):
            res.value(key, "elf.%s:%s" % (prop, p), pm.text(fa.get(prop)), fb.get(prop),
                      detail={"raw": fa.get(prop)})
        ea, eb = Elf(ours), Elf(off)
        # relocatable objects: the string sections are compared as one pool
        # (a longer path constant changes its section's alignment class,
        # .rodata.str1.16 -> .rodata.str1.32)
        pool = self.string_pool(ea, eb) if ea.etype == 1 else None
        secs_a, secs_b = fa.get("sections") or [], fb.get("sections") or []
        if pool is not None:
            canon = lambda xs: sorted({STRSEC.sub(".rodata.str*", x) for x in xs})
            secs_a, secs_b = canon(secs_a), canon(secs_b)
        res.setdiff(key, "elf.section:" + p, secs_a, secs_b)
        self.alloc(p, ea, eb, fa, fb, ours, off, ours_path, pool)
        for prop, did in (("dynsyms", "elf.dynsym"), ("symbols", "elf.symbol")):
            a, b = fa.get(prop) or [], fb.get(prop) or []
            if pool is not None:
                a = [STRSEC.sub(".rodata.str*", x) for x in a]
                b = [STRSEC.sub(".rodata.str*", x) for x in b]
            a, b = self.pathsized(p, ea, eb, a, b, prop)
            res.setdiff(key, "%s:%s" % (did, p), a, b)
        res.setdiff(key, "elf.verdef:" + p, fa.get("verdef") or [], fb.get("verdef") or [])
        res.setdiff(key, "elf.verneed:" + p, fa.get("verneed") or [], fb.get("verneed") or [])
        seg = lambda f: [re.sub(r" (off|vaddr|filesz|memsz)=0x[0-9a-f]+", "", s) for s in f.get("segments") or []]
        sga, sgb = seg(fa), seg(fb)
        if ia == ib and fa.get("interp") != fb.get("interp"):
            # a longer PT_INTERP string (the store loader path) gets gcc's
            # 32-byte array alignment (glibc's own .interp in libc.so.6)
            nointerp = lambda xs: [re.sub(r"^(INTERP .*) align=0x[0-9a-f]+$", r"\1", x) for x in xs]
            if sga != sgb and nointerp(sga) == nointerp(sgb):
                res.count("interp_align")
                sga, sgb = nointerp(sga), nointerp(sgb)
        res.value(key, "elf.segments:" + p, sga, sgb)
        if ea.etype == 1:
            self.relocs(p, ea, eb, pool)

    # ---- string sections of relocatable objects
    def string_pool(self, ea, eb):
        """None, or {"a": {key}, "b": {key}} when the strings of all
        SHF_STRINGS sections match as pools (after the map)"""
        ka = [s for s in ea.sh if s["flags"] & SHF_STRINGS and s["flags"] & SHF_ALLOC]
        kb = [s for s in eb.sh if s["flags"] & SHF_STRINGS and s["flags"] & SHF_ALLOC]
        if not ka and not kb:
            return None
        da = b"\0".join(self.pm.data(ea.data(s))[0] for s in ka)
        db = b"\0".join(eb.data(s) for s in kb)
        if not self.strings_equal(da, db):
            return None
        return {"a": {s["key"] for s in ka}, "b": {s["key"] for s in kb}}

    def alloc(self, p, ea, eb, fa, fb, ours, off, ours_path, pool):
        res, key, pm = self.res, self.key, self.pm
        sa = {s["key"]: s for s in ea.sh if s["flags"] & SHF_ALLOC and s["name"] != ".note.gnu.build-id"}
        sb = {s["key"]: s for s in eb.sh if s["flags"] & SHF_ALLOC and s["name"] != ".note.gnu.build-id"}
        if pool is not None:
            for k in pool["a"]:
                sa.pop(k, None)
            for k in pool["b"]:
                sb.pop(k, None)
            res.count("alloc_string_pool")
        pending_layout, moved = [], pool is not None
        for k in sorted(set(sa) | set(sb)):
            a, b = sa.get(k), sb.get(k)
            if a is None or b is None:
                res.diff(key, "elf.alloc:%s:%s" % (p, k), a and a["size"], b and b["size"])
                continue
            da, db = ea.data(a), eb.data(b)
            if a["type"] != b["type"] or (a["flags"] & ~SHF_ALLOC) != (b["flags"] & ~SHF_ALLOC):
                res.diff(key, "elf.alloc:%s:%s" % (p, k), "type 0x%x flags 0x%x" % (a["type"], a["flags"]),
                         "type 0x%x flags 0x%x" % (b["type"], b["flags"]))
                continue
            if a["size"] != b["size"]:
                moved = True
            if a["type"] == 8:   # NOBITS
                if a["size"] != b["size"]:
                    pending_layout.append((k, a, b))
                else:
                    res.count("alloc_identical")
                continue
            if da == db:
                res.count("alloc_identical")
                continue
            if k == ".interp":
                moved = True
                res.count("alloc_interp")   # compared as elf.interp
                continue
            md, spans = pm.data(da)
            if spans and md == db:
                moved = True
                res.count("alloc_path_map")
                continue
            if a["flags"] & SHF_EXECINSTR:
                if self.disasm_equal(p, k, ours, off, ours_path):
                    res.count("alloc_displacement")
                    moved = True
                    continue
                res.diff(key, "elf.alloc:%s:%s" % (p, k), self.h(da), self.h(db), detail="code differs beyond "
                         "RIP-relative displacements and addresses (objdump)")
                continue
            if k == ".dynstr":
                rp_ = [x.encode() for x in (fa.get("runpath"), fa.get("rpath")) if x]
                sa_ = [x for x in strings_of(da) if x not in rp_]
                if strings_of(pm.data(b"\0".join(sa_))[0]) == strings_of(db):
                    res.count("alloc_dynstr")
                    moved = True
                    continue
            if a["size"] == b["size"] and (k in LAYOUT_SECS or not k.startswith(".rodata")):
                pending_layout.append((k, a, b))
                continue
            if self.strings_equal(md, db):
                moved = True
                res.count("alloc_strings")
                continue
            if k.startswith(".rodata") and self.rodata_equal(da, db):
                moved = True
                res.count("alloc_rodata_tables")
                continue
            res.diff(key, "elf.alloc:%s:%s" % (p, k), self.h(da), self.h(db),
                     detail="%d store path(s) in ours; sizes 0x%x/0x%x" % (len(spans), a["size"], b["size"]))
        for k, a, b in pending_layout:
            if moved:
                res.count("alloc_layout")
            else:
                res.diff(key, "elf.alloc:%s:%s" % (p, k), self.h(ea.data(a)), self.h(eb.data(b)),
                         detail="same size, different bytes, and nothing in the file moved")

    @staticmethod
    def h(b):
        return "%d %s" % (len(b), hashlib.sha256(b).hexdigest()[:16])

    def canon_strings(self, xs, side):
        return {x.encode("latin-1") for x in self.res.rules.apply_rewrites(
            self.key, "elf.strings", side, sorted(x.decode("latin-1") for x in xs))}

    def strings_equal(self, md, db):
        """same strings after the path map, usrmerge spellings and the
        allowlist's rewrite rules for field elf.strings (tail merges allowed)"""
        return strings_match(self.canon_strings(string_set(md), "ours"),
                             self.canon_strings(string_set(db), "official"))

    def rodata_equal(self, da, db):
        """.rodata with strings AND binary data: NUL-separated chunks aligned
        in order; text chunks must match after the map (tails allowed),
        binary chunks must be equal or differ word-wise by a constant per run
        (32-bit relative offsets, e.g. switch jump tables, whose distance to
        the code moved).  Positions are in the unmapped section bytes."""
        def chunks(b, side, mapped):
            out, pos = [], 0
            for x in b.split(b"\0"):
                if x:
                    if mapped:
                        mx = self.pm.data(x)[0]
                    else:
                        mx = x
                    t = printable(mx)
                    if t:
                        r = self.canon_strings([usrmerge_data(mx)], side)
                        mx = next(iter(r)) if r else usrmerge_data(mx)
                    out.append((t, mx, pos, len(x)))
                pos += len(x) + 1
            return out
        ca, cb = chunks(da, "ours", True), chunks(db, "official", False)
        ka = [(c[0], c[1]) for c in ca]
        kb = [(c[0], c[1]) for c in cb]
        tails_a = {x[i:] for t, x in ka if t for i in range(len(x))}
        tails_b = {x[i:] for t, x in kb if t for i in range(len(x))}
        sm = difflib.SequenceMatcher(None, ka, kb, autojunk=False)
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op == "equal":
                continue
            ta = [x for t, x in ka[i1:i2] if t]
            tb = [x for t, x in kb[j1:j2] if t]
            if not all(x in tails_b for x in ta) or not all(x in tails_a for x in tb):
                return False
            # binary bytes of the block: same length, word deltas constant per run
            ba = [ca[i] for i in range(i1, i2) if not ca[i][0]]
            bb = [cb[j] for j in range(j1, j2) if not cb[j][0]]
            if not ba and not bb:
                continue
            if not ba or not bb:
                return False
            sa_, ea_ = ba[0][2], ba[-1][2] + ba[-1][3]
            sb_, eb_ = bb[0][2], bb[-1][2] + bb[-1][3]
            sa_, sb_ = sa_ - sa_ % 4, sb_ - sb_ % 4
            if ea_ - sa_ != eb_ - sb_:
                return False
            if not words_shifted(da[sa_:ea_], db[sb_:eb_]):
                return False
        return True

    def disasm_equal(self, p, k, ours, off, ours_path):
        d = tempfile.mkdtemp(dir=self.workdir)
        try:
            pa = ours_path
            if pa is None or "(" in p:
                pa = os.path.join(d, "ours")
                with open(pa, "wb") as f:
                    f.write(ours)
            pb = os.path.join(d, "official")
            with open(pb, "wb") as f:
                f.write(off)
            name = k.split("#")[0]
            try:
                return disasm(pa, name) == disasm(pb, name)
            except ToolError as e:
                self.res.info.append(str(e))
                return False
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def pathsized(self, p, ea, eb, a, b, prop):
        """drop pairs 'X ... size' / 'X ... size2' whose objects are equal
        after the path map (a relocated default path string)"""
        sa, sb = set(a) - set(b), set(b) - set(a)
        if not sa or not sb:
            return a, b
        strip = lambda s: s.rsplit(" ", 1)[0]
        bym = {}
        for x in sb:
            bym.setdefault(strip(x), []).append(x)
        drop_a, drop_b = set(), set()
        for x in sa:
            cand = bym.get(strip(x))
            if not cand or len(cand) != 1:
                continue
            nm = x.split(" ", 1)[0].split("@")[0]
            oa, ob = self.find_obj(ea, nm, prop), self.find_obj(eb, nm, prop)
            if oa is None or ob is None:
                continue
            ma = usrmerge_data(self.pm.data(oa)[0]).rstrip(b"\0")
            if ma == usrmerge_data(ob).rstrip(b"\0"):
                drop_a.add(x)
                drop_b.add(cand[0])
                self.res.count("pathsized_symbols")
        return [x for x in a if x not in drop_a], [x for x in b if x not in drop_b]

    @staticmethod
    def find_obj(e, name, prop):
        want = 11 if prop == "dynsyms" else 2
        for s in e.sh:
            if s["type"] != want:
                continue
            for sy in e.symbols(s):
                if sy["name"] == name and sy["shndx"] and sy["type"] == 1:
                    return e.object_bytes(sy)
        return None

    def relocs(self, p, ea, eb, pool):
        """relocations against loaded sections; targets inside string
        sections are named by the string they point into (after the map)"""
        def norm(e, side):
            out = {}
            strs = {}
            for k, lst in e.relocs().items():
                if pool is not None and k in pool[side]:
                    continue
                nl = []
                for off, rt, tgt, add, tsec in lst:
                    if tsec is not None and e.sh[tsec]["flags"] & SHF_STRINGS:
                        if tsec not in strs:
                            strs[tsec] = e.data(e.sh[tsec])
                        t = add + (4 if rt in (2, 4, 9, 41, 42) else 0)
                        tgt, add = string_at(strs[tsec], t, self.pm if side == "a" else None)
                        if pool is not None:
                            tgt = "[str]" + tgt
                        nl.append((off, rt, tgt, add))
                    else:
                        nl.append((off, rt, tgt, add))
                kk = STRSEC.sub(".rodata.str*", k) if pool is not None else k
                out[kk] = nl
            return out
        ra, rb = norm(ea, "a"), norm(eb, "b")
        for k in sorted(set(ra) | set(rb)):
            na, nb = ra.get(k, []), rb.get(k, [])
            if na != nb:
                self.res.diff(self.key, "elf.relocs:%s:%s" % (p, k), len(na), len(nb),
                              detail={"diff": list(difflib.unified_diff(
                                  ["%x %d %s %d" % x for x in nb], ["%x %d %s %d" % x for x in na],
                                  "official", "ours", lineterm="", n=0))[:40]})


STRSEC = re.compile(r"\.rodata\.str1\.\d+")


def printable(x):
    return len(x) >= 3 and all(32 <= c < 127 or c in (9, 10) for c in x)


def string_at(data, t, pm):
    """(string containing offset t, mapped, quoted) and the offset inside it"""
    if t < 0 or t >= len(data):
        return "@%d" % t, 0
    s = data.rfind(b"\0", 0, t) + 1 if t > 0 else 0
    if t < len(data) and data[t:t + 1] == b"\0" and t > 0 and data[t - 1:t] != b"\0":
        s = data.rfind(b"\0", 0, t) + 1
    e = data.find(b"\0", s)
    e = len(data) if e < 0 else e
    x = data[s:e]
    intra = t - s
    if pm is not None:
        mx, spans = pm.data(x)
        # an offset behind a replaced path moves with it
        intra -= sum((b - a) - 4 for a, b in spans if b <= intra)
        x = mx
    return '"%s"' % usrmerge_data(x).decode("latin-1"), intra


def words_shifted(a, b):
    """equal-length byte strings: every differing little-endian 32-bit word
    belongs to a run whose words all differ by the same delta"""
    if len(a) != len(b):
        return False
    n = len(a) // 4
    prev = None
    for i in range(n):
        wa = int.from_bytes(a[4 * i:4 * i + 4], "little", signed=True)
        wb = int.from_bytes(b[4 * i:4 * i + 4], "little", signed=True)
        d = wa - wb
        if d == 0:
            prev = None
            continue
        if abs(d) >= 1 << 20:
            return False
        if prev is not None and d != prev:
            return False
        prev = d
    return a[4 * n:] == b[4 * n:]


def compare_ar(ec, p, ours, off):
    res, key = ec.res, ec.key
    aa, ab = rp.parse_ar(ours), rp.parse_ar(off)
    if aa is None or ab is None:
        res.diff(key, "ar.error:" + p, aa is None, ab is None)
        return
    if aa["members"] != ab["members"]:
        res.diff(key, "ar.members:" + p, len(aa["members"]), len(ab["members"]))
    res.setdiff(key, "ar.armap:" + p, aa["armap"], ab["armap"])
    ma, mb = ar_bodies(ours), ar_bodies(off)
    for k in sorted(set(ma) & set(mb)):
        xa, xb = ma[k], mb[k]
        q = "%s(%s)" % (p, k)
        if xa == xb:
            res.count("ar_member_identical")
            continue
        if xa[:4] == b"\x7fELF" and xb[:4] == b"\x7fELF":
            res.count("ar_member_elf_compared")
            ec.compare(q, xa, xb)
        else:
            md, spans = ec.pm.data(xa)
            if spans and md == xb:
                res.count("ar_member_path_map")
            else:
                res.diff(key, "ar.member:" + q, ec.h(xa), ec.h(xb))


def ar_bodies(data):
    """member key -> body (keys as rpm-parity's parse_ar)"""
    p, names, bodies, longnames = 8, [], [], b""
    while p + 60 <= len(data):
        h = data[p:p + 60]
        name = h[:16].decode("latin-1").rstrip()
        size = int(h[48:58].decode("ascii").strip() or 0)
        body = data[p + 60:p + 60 + size]
        p += 60 + size + (size & 1)
        if name == "//":
            longnames = body
            continue
        if name in ("/", "/SYM64/"):
            continue
        if name.startswith("/") and name[1:].isdigit():
            o = int(name[1:])
            name = longnames[o:longnames.index(b"\n", o)].decode("latin-1")
        names.append(name.rstrip("/"))
        bodies.append(body)
    return dict(zip(rp._unique_names(names), bodies))


def is_text(b):
    if b"\0" in b[:65536]:
        return False
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


# --------------------------------------------------------------------------- content
def check_content(plan, rules, out, workdir):
    pm = PathMap(plan["outputs"])
    res = Result("content", rules)
    rpm_out = plan["rpmOutputs"]
    for name, rpath in sorted(plan["official"].items()):
        off = Official(rpath)
        key = off.key
        o = rpm_out.get(name)
        root = plan["outputs"].get(o or "", None)
        if root is None:
            res.diff(key, "content.no-output", o, name)
            continue
        ec = ElfCompare(res, key, pm, workdir)
        want, todo = set(), []
        for rel, fe in sorted(off.files.items()):
            if (fe["mode"] & S_IFMT) != S_IFREG:
                continue
            q = os.path.join(root, rel)
            if not os.path.isfile(q) or os.path.islink(q):
                continue   # the files check reports it
            res.count("files")
            if fe["size"] == 0 and os.path.getsize(q) == 0:
                res.count("identical")
                continue
            if fe["digest"] and sha256_file(q, off.rpm.digestalgo) == fe["digest"]:
                res.count("identical")
                continue
            want.add(fe["group_id"])
            todo.append((rel, fe, q))
        if not todo:
            continue
        data = off.payload(want)
        for rel, fe, q in todo:
            p = fe["path"]
            with open(q, "rb") as f:
                a = f.read()
            b = data.get(fe["group_id"])
            if b is None:
                res.diff(key, "content.no-payload:" + p, len(a), None)
                continue
            if a == b:
                res.count("identical")
                continue
            if a[:4] == b"\x7fELF" and b[:4] == b"\x7fELF":
                res.count("elf_compared")
                ec.compare(p, a, b, ours_path=q)
            elif a[:8] == b"!<arch>\n" and b[:8] == b"!<arch>\n":
                res.count("ar_compared")
                compare_ar(ec, p, a, b)
            else:
                md, spans = pm.data(a)
                if spans and md == b:
                    res.count("path_map_equal")
                    continue
                if is_text(a) and is_text(b):
                    ta, tb = usrmerge_text(md.decode()), usrmerge_text(b.decode())
                    if ta == tb:
                        res.count("text_equal_usrmerge")
                        continue
                    ud = list(difflib.unified_diff(tb.splitlines(), ta.splitlines(),
                                                   "official" + p, "ours" + p, lineterm="", n=1))
                    res.diff(key, "content.text:" + p, ec.h(a), ec.h(b), detail={"diff": ud[:200]})
                else:
                    res.diff(key, "content.bytes:" + p, ec.h(a), ec.h(b),
                             detail="%d store path(s) in ours" % len(spans))
    return res.finish(out, plan.get("name", "?"))


# --------------------------------------------------------------------------- abi
def check_abi(plan, rules, out, workdir):
    ab = _load("abi_compare", "abi-compare.py")
    pm = PathMap(plan["outputs"])
    orig_run = ab.run
    ab.run = lambda *cmd: pm.text(orig_run(*cmd))     # the path map
    res = Result("abi", rules)
    rpm_out = plan["rpmOutputs"]
    stats = {}

    class Allow:   # abi-compare's interface over our Rules
        def match(self, pkg, did):
            return None   # matched below, with the changed lines as ours/official

    for name, rpath in sorted(plan["official"].items()):
        off = Official(rpath)
        key = off.key
        o = rpm_out.get(name)
        root = plan["outputs"].get(o or "", None)
        if root is None:
            res.diff(key, "abi.no-output", o, name)
            continue
        base = os.path.join(workdir, "abi", name)
        vo, vf = os.path.join(base, "ours"), os.path.join(base, "official")
        want = {}
        for rel, fe in off.files.items():
            if (fe["mode"] & S_IFMT) != S_IFREG:
                continue
            q = os.path.join(root, rel)
            if not os.path.isfile(q) or os.path.islink(q):
                continue
            cls = fe["class"] or ""
            if not (fe["path"].startswith("/usr/include/") or cls.startswith("ELF") or "ar archive" in cls
                    or not cls):
                continue
            with open(q, "rb") as f:
                head = f.read(8)
            if not (fe["path"].startswith("/usr/include/") or head[:4] == b"\x7fELF" or head == b"!<arch>\n"):
                continue
            dst = os.path.join(vo, fe["path"].lstrip("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(q, dst)
            want[fe["group_id"]] = want.get(fe["group_id"], []) + [fe["path"]]
        if not want:
            continue
        for g, data in off.payload(set(want)).items():
            for pth in want[g]:
                dst = os.path.join(vf, pth.lstrip("/"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "wb") as f:
                    f.write(data)
        stats["packages"] = stats.get("packages", 0) + 1
        for d in ab.compare_pair(key, vo, vf, Allow(), stats):
            if d["id"].startswith("abi.dynsym:"):
                d = reclassify_dynsym(d, vo, vf, pm, res)
                if d is None:
                    continue
            ud = d.pop("diff", None)
            if ud:
                ours = [x[1:] for x in ud[2:] if x.startswith("+")]
                offl = [x[1:] for x in ud[2:] if x.startswith("-")]
            else:
                ours, offl = d.get("ours"), d.get("official")
            res.diff(key, d["id"], ours, offl, detail={"diff": ud} if ud else None)
        shutil.rmtree(base, ignore_errors=True)
    res.stats.update(stats)
    summary = ["ELF DSOs/executables %d (%d dynamic symbols); relocatable objects %d; static archives %d "
               "(%d members, %d external symbols); headers %d" % tuple(
                   stats.get(k, 0) for k in ("elf", "dynsyms", "rel", "ar", "ar_members", "static_symbols",
                                             "header"))]
    if not stats.get("packages"):
        raise ToolError("abi: nothing compared")
    return res.finish(out, plan.get("name", "?"), extra={"summary": summary})


def reclassify_dynsym(d, vo, vf, pm, res):
    """drop the line pairs of an abi.dynsym difference that are objects whose
    size changed with a relocated path (equal bytes after the map; counted,
    not reported); None when nothing else is left"""
    p = d["id"].split(":", 1)[1]
    ud = d.get("diff") or []
    plus = [x[1:] for x in ud[2:] if x.startswith("+")]
    minus = [x[1:] for x in ud[2:] if x.startswith("-")]
    strip = lambda s: s.rsplit(" ", 1)[0]
    bym = {}
    for x in minus:
        bym.setdefault(strip(x), []).append(x)
    with open(os.path.join(vo, p.lstrip("/")), "rb") as f:
        ea = Elf(f.read())
    with open(os.path.join(vf, p.lstrip("/")), "rb") as f:
        eb = Elf(f.read())
    gone = set()
    for x in plus:
        cand = bym.get(strip(x))
        if not cand or len(cand) != 1 or " OBJECT " not in x:
            continue
        nm = x.split(" ", 1)[0].split("@")[0]
        oa, ob = ElfCompare.find_obj(ea, nm, "dynsyms"), ElfCompare.find_obj(eb, nm, "dynsyms")
        if oa is None or ob is None:
            continue
        if usrmerge_data(pm.data(oa)[0]).rstrip(b"\0") != usrmerge_data(ob).rstrip(b"\0"):
            continue
        gone |= {"+" + x, "-" + cand[0]}
        res.count("pathsized_dynsyms")
        res.info.append("%s: %s differs only by a relocated path (%s)" % (p, nm, strip(x)))
    if not gone:
        return d
    rest = [x for x in ud[2:] if x not in gone and not x.startswith("@@")]
    if not rest:
        return None
    return dict(d, diff=ud[:2] + rest)


# --------------------------------------------------------------------------- closure
def read_graph(path):
    """exportReferencesGraph file -> {path: [refs]}"""
    g = {}
    with open(path) as f:
        lines = f.read().split("\n")
    i = 0
    while i < len(lines) and lines[i]:
        p, n = lines[i], int(lines[i + 2])
        g[p] = lines[i + 3:i + 3 + n]
        i += 3 + n
    return g


def check_closure(plan, rules, out, graphs):
    """every output's closure inside siblings + extraAllowed (+ their
    closures); a foreign path is reported once, at the edge where it enters
    (the sibling output or allowed path that references it), with the
    outputs whose closures it reaches"""
    res = Result("closure", rules)
    outs = plan["outputs"]
    sib = set(outs.values())
    owner = {p: o for o, p in outs.items()}
    graph, per = {}, {}
    for o in sorted(outs):
        gp = os.path.join(graphs, "graph-" + o)
        if not os.path.exists(gp):
            raise ToolError("closure: no graph file for output %s" % o)
        g = read_graph(gp)
        graph.update(g)
        per[o] = g
    allowed = set(plan.get("extraAllowed", []))
    stack = list(allowed)
    while stack:
        x = stack.pop()
        for r in graph.get(x, []):
            if r not in allowed:
                allowed.add(r)
                stack.append(r)
    ok = sib | allowed
    edges, entries, reach = {}, {}, {}
    nocheck = {o for o in ("debug", "logs") if o in outs}
    for o in sorted(outs):
        g = per[o]
        p = outs[o]
        refs = [r for r in g.get(p, []) if r != p]
        edges[o] = sorted(owner.get(r, r) for r in refs)
        foreign = [x for x in g if x not in ok]
        res.count("outputs")
        res.count("closure_paths", len(g))
        if foreign:
            res.count("outputs_with_foreign")
        for x in foreign:
            reach.setdefault(x, set()).add(o)
        for n in nocheck:
            if o != n and outs[n] in refs:
                res.diff("output:" + o, "closure.debug-ref:" + n, n, None)
    for x, rs in graph.items():
        if x not in ok:
            continue
        for r in rs:
            if r not in ok:
                entries.setdefault((owner.get(x, x), r), True)
    for (src, r) in sorted(entries):
        res.diff("output:" + src if src in outs else src,
                 "closure.foreign:" + re.sub(r"^/nix/store/[0-9a-z]{32}-", "", r), r, None,
                 detail={"enters_via": src, "closures_reached": len(reach.get(r, ())),
                         "foreign_paths_below": len(below(graph, r))})
    res.stats["foreign_paths"] = len(reach)
    return res.finish(out, plan.get("name", "?"), extra={"edges": edges, "summary": [
        "outputs %d; closures must stay within the %d siblings + %d allowed path(s); foreign paths %d "
        "(entry edges %d)" % (len(outs), len(sib), len(set(plan.get("extraAllowed", []))), len(reach),
                              len(entries))]})


def below(graph, r):
    seen, stack = set(), [r]
    while stack:
        x = stack.pop()
        for y in graph.get(x, []):
            if y not in seen:
                seen.add(y)
                stack.append(y)
    return seen


# --------------------------------------------------------------------------- runtime
ADDR_RE = re.compile(r"\(0x[0-9a-f]+\)")
ITEM_RE = re.compile(r"^### (\S+)\s*$")


IDENTITY_RE = re.compile(r"^(\s*)(\S+) => \2 \(ADDR\)$", re.M)


def normalize_runtime(text, pm):
    """output paths -> /usr, map labels, addresses, usrmerge spellings; and
    ld.so's "name => path" when both are the same after that (the official
    PT_INTERP /lib64/ld-linux... resolves to /usr/lib64/...)"""
    text = pm.text(text)
    text = ADDR_RE.sub("(ADDR)", text)
    text = usrmerge_text(text)
    text = IDENTITY_RE.sub(r"\1\2 (ADDR)", text)
    return text


def parse_items(text):
    items, cur, order = {}, None, []
    for line in text.splitlines():
        m = ITEM_RE.match(line)
        if m:
            cur = m.group(1)
            if cur in items:
                raise ToolError("runtime report: item %s twice" % cur)
            items[cur] = []
            order.append(cur)
            continue
        if cur is not None:
            items[cur].append(line)
    return items, order


def check_runtime(plan, rules, out, ours_dir, off_dir):
    pm = PathMap(plan["outputs"], plan.get("map"))
    res = Result("runtime", rules)
    problems = []
    for fn in sorted(os.listdir(off_dir)):
        if not fn.endswith(".txt"):
            continue
        po, pf = os.path.join(ours_dir, fn), os.path.join(off_dir, fn)
        if not os.path.exists(po):
            res.diff(fn, "runtime.missing-report:" + fn, None, fn)
            continue
        with open(po, errors="replace") as f:
            to = normalize_runtime(f.read(), pm)
        with open(pf, errors="replace") as f:
            tf = normalize_runtime(f.read(), PathMap({}))
        io_, oo = parse_items(to)
        if_, of = parse_items(tf)
        res.count("reports")
        for it in oo:
            if it not in if_:
                res.diff(fn, "runtime.only-ours:" + it, io_[it][:20], None)
        for it in of:
            res.count("items")
            if it not in io_:
                res.diff(fn, "runtime.only-official:" + it, None, if_[it][:20])
                continue
            a, b = io_[it], if_[it]
            if a == b:
                res.count("items_equal")
                continue
            ud = list(difflib.unified_diff(b, a, "official", "ours", lineterm="", n=0))
            # ours/official = the changed lines, so allowlist rules can pin them
            plus = [x[1:] for x in ud[2:] if x.startswith("+")]
            minus = [x[1:] for x in ud[2:] if x.startswith("-")]
            res.diff(fn, "runtime.item:" + it, plus, minus, detail={"diff": ud[:120]})
    for fn in sorted(os.listdir(ours_dir)):
        if fn.endswith(".txt") and not os.path.exists(os.path.join(off_dir, fn)):
            res.info.append("ours-only report %s (checked by assertions, not compared)" % fn)
    if not res.stats.get("items"):
        problems.append("no runtime items compared")
    return res.finish(out, plan.get("name", "?"), require=problems)


# --------------------------------------------------------------------------- selftest (pure)
def selftest():
    """unit tests of the path logic; the comparators are exercised end to end
    by checks.nn-parity-selftest (lib/rocky/nn-checks/selftest.nix)"""
    o = "/nix/store/" + "a" * 32 + "-x-1.0"
    d = "/nix/store/" + "b" * 32 + "-x-1.0-dev"
    pm = PathMap({"out": o, "dev": d})
    assert fhs2rel("/usr/lib64/libx.so") == "lib64/libx.so"
    assert fhs2rel("/etc/x.conf") == "etc/x.conf"
    assert rel2fhs("etc/x.conf") == "/etc/x.conf" and rel2fhs("bin/x") == "/usr/bin/x"
    assert usrmerge("/lib64/libc.so.6") == "/usr/lib64/libc.so.6" and usrmerge("/etc/a") == "/etc/a"
    assert pm.text("%s/lib64:%s/include" % (o, d)) == "/usr/lib64:/usr/include"
    assert pm.data(("x%s/share\0" % d).encode()) == (b"x/usr/share\0", [(1, 1 + len(d))])
    assert our_target(pm, "dev", "lib64/libx.so", o + "/lib64/libx.so.1") == "/usr/lib64/libx.so.1"
    assert our_target(pm, "out", "lib64/libx.so", "libx.so.1") == "/usr/lib64/libx.so.1"
    assert our_target(pm, "out", "share/a/b", "../../etc/x") == "/etc/x"
    assert our_target(pm, "out", "etc/localtime", "/etc/zoneinfo") == "/etc/zoneinfo"
    assert official_target("/usr/lib64/libx.so", "libx.so.1") == "/usr/lib64/libx.so.1"
    assert official_target("/usr/bin/x", "../../lib64/y") == "/usr/lib64/y"
    t = "### a\n x %s/lib64/libc.so.6 (0x00007f00)\n### b\n/lib64/ld.so\n\t/lib64/l.so => /usr/lib64/l.so (0x1)\n" % o
    items, order = parse_items(normalize_runtime(t, pm))
    assert order == ["a", "b"] and items["a"] == [" x /usr/lib64/libc.so.6 (ADDR)"], items
    assert items["b"] == ["/usr/lib64/ld.so", "\t/usr/lib64/l.so (ADDR)"], items
    assert usrmerge_text("/lib: x /lib64/a /usr/lib64 a/lib/b") == "/usr/lib: x /usr/lib64/a /usr/lib64 a/lib/b"
    assert usrmerge_text('d="<libgcc>/lib64/" <libgcc>/lib x') == 'd="<libgcc>/lib64/" <libgcc>/lib x'
    print("nn-parity selftest (unit): PASS")
    return 0


def meta_from_rpm(rpm_path, output, out):
    """nix-support/rpm/<subpkg>.json in the partitioner's format, from an RPM
    header (synthetic test fixtures; the real ones come from rocky-partition)"""
    r = rp.Rpm(rpm_path)
    files = []
    for p, fe in sorted(r.files.items()):
        m = fe["mode"] & S_IFMT
        files.append({"path": p, "rel": fhs2rel(p), "mode": "%o" % fe["mode"], "flags": rp.fmt_flags(fe["flags"]).strip("-"),
                      "user": fe["user"], "group": fe["group"], "caps": fe["caps"] or None,
                      "linkto": fe["linkto"] or None, "digest": fe["digest"] or None, "size": fe["size"],
                      "ghost": bool(fe["flags"] & 64), "config": bool(fe["flags"] & 1),
                      "type": "dir" if m == S_IFDIR else "link" if m == S_IFLNK else "file"})
    meta = {"name": r.name, "output": output, "files": files}
    for kind, n, v, f in rp.DEPKINDS:
        if kind == "order":
            continue
        names = r.v(n) or []
        vers = r.v(v) or [""] * len(names)
        flags = r.v(f) or [0] * len(names)
        meta[kind] = [{"name": a, "version": b, "flags": c} for a, b, c in zip(names, vers, flags)]
    with open(out, "w") as f:
        json.dump(meta, f, indent=1, sort_keys=True)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="relocated parity checks (design §7.4-§7.6)")
    ap.add_argument("check", choices=["files", "content", "abi", "closure", "runtime", "selftest", "meta-from-rpm"])
    ap.add_argument("--rpm")
    ap.add_argument("--output-name")
    ap.add_argument("--plan")
    ap.add_argument("--allow", action="append", default=[])
    ap.add_argument("--no-default-allow", action="store_true")
    ap.add_argument("--out", default=".")
    ap.add_argument("--graphs")
    ap.add_argument("--ours")
    ap.add_argument("--official")
    ap.add_argument("--workdir", default=None)
    a = ap.parse_args(argv)
    if a.check == "selftest":
        return selftest()
    if a.check == "meta-from-rpm":
        return meta_from_rpm(a.rpm, a.output_name, a.out)
    if not a.plan:
        raise ToolError("--plan is required")
    plan = load_plan(a.plan)
    rules = load_rules(a.allow, default=not a.no_default_allow)
    work = a.workdir or tempfile.mkdtemp(prefix="nn-parity-")
    os.makedirs(work, exist_ok=True)
    if a.check == "files":
        return check_files(plan, rules, a.out)
    if a.check == "content":
        return check_content(plan, rules, a.out, work)
    if a.check == "abi":
        return check_abi(plan, rules, a.out, work)
    if a.check == "closure":
        if not a.graphs:
            raise ToolError("closure needs --graphs")
        return check_closure(plan, rules, a.out, a.graphs)
    if a.check == "runtime":
        if not (a.ours and a.official):
            raise ToolError("runtime needs --ours and --official")
        return check_runtime(plan, rules, a.out, a.ours, a.official)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ToolError, OSError, ValueError, KeyError) as e:
        print("nn-parity: error: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(2)
