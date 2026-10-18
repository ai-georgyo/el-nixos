#!/usr/bin/env python3
"""Spike analysis of a relocated rpmbuild: %files partition, references to the
placeholder prefix P (owner resolution, contexts, cross-subpackage graph, SCCs),
leftover FHS (/usr) references and foreign store paths.

usage: analyze.py RPMSDIR P OUTDIR      (runs inside the build chroot: /usr = view)
"""
import collections, gzip, json, os, re, struct, subprocess, sys

rpmsdir, P, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
Pb = P.encode()
os.makedirs(outdir, exist_ok=True)
ex = os.path.join(outdir, "x")
os.makedirs(ex, exist_ok=True)

PATHCH = re.compile(rb"[A-Za-z0-9._+\-/@%~,=]*")
FHS_TOP = ("etc", "var", "run", "boot", "opt", "srv", "root", "home", "tmp")
USRMOVE = {"bin": "bin", "sbin": "sbin", "lib": "lib", "lib64": "lib64"}


def q(f, fmt):
    return subprocess.run(["rpm", "-qp", "--nosignature", "--nodigest", "--qf", fmt, f],
                          check=True, capture_output=True).stdout.decode("utf-8", "surrogateescape")


def canon(path):
    """payload path -> (space, rel, how)"""
    if path == P or path.startswith(P + "/"):
        return "P", path[len(P):].lstrip("/"), "prefix"
    parts = path.lstrip("/").split("/", 1)
    top, rest = parts[0], (parts[1] if len(parts) > 1 else "")
    if top == "usr":
        return "P", rest, "hardcoded-usr"
    if top in USRMOVE:
        return "P", (USRMOVE[top] + "/" + rest).rstrip("/"), "usrmove"
    if top in FHS_TOP:
        return "FHS", path, "fhs-" + top
    if top == "nix":
        return "STORE?", path, "other-store"
    return "OTHER", path, "other-" + top


pkgs = {}
for arch in sorted(os.listdir(rpmsdir)):
    for fn in sorted(os.listdir(os.path.join(rpmsdir, arch))):
        if not fn.endswith(".rpm"):
            continue
        f = os.path.join(rpmsdir, arch, fn)
        name = q(f, "%{NAME}")
        lst = q(f, "[%{FILENAMES}\t%{FILEFLAGS:fflags}\t%{FILEMODES:perms}\t%{FILELINKTOS}\n]")
        files = []
        for line in lst.splitlines():
            if not line:
                continue
            p, fl, mode, lt = (line.split("\t") + ["", "", ""])[:4]
            files.append({"path": p, "flags": fl, "mode": mode, "link": lt})
        d = os.path.join(ex, name)
        os.makedirs(d, exist_ok=True)
        subprocess.run("rpm2cpio '%s' | (cd '%s' && cpio -idm --quiet --no-absolute-filenames)" % (f, d),
                       shell=True, check=True)
        pkgs[name] = {"file": fn, "files": files, "dir": d,
                      "debug": name.endswith("-debuginfo") or name.endswith("-debugsource")}

# ownership
fowners = collections.defaultdict(set)   # rel -> pkgs (non-dir entries)
downers = collections.defaultdict(set)   # rel dir (ancestor) -> pkgs having content below
placement = collections.Counter()
placement_by_pkg = {}
for n, pk in pkgs.items():
    c = collections.Counter()
    for fe in pk["files"]:
        sp, rel, how = canon(fe["path"])
        c[how] += 1
        placement[how] += 1
        if sp != "P":
            continue
        if fe["mode"].startswith("d"):
            downers[rel].add(n)
        else:
            fowners[rel].add(n)
        parts = rel.split("/")
        for i in range(len(parts)):
            downers["/".join(parts[:i])].add(n)
    placement_by_pkg[n] = dict(c)


def norm(rel):
    rel = rel.decode("utf-8", "surrogateescape")
    rel = re.sub(r"/+", "/", rel)
    rel = re.sub(r"(/\.)+(/|$)", "/", rel)
    return rel.strip("/")


def resolve(rel, me):
    if rel == "":
        return "bare", [me]
    if rel in fowners:
        o = fowners[rel]
        return ("self", [me]) if me in o else ("file", sorted(o))
    if rel in downers:
        o = downers[rel]
        if me in o:
            return "self-dir", [me]
        return ("dir", sorted(o)) if len(o) == 1 else ("split-dir", sorted(o))
    if os.path.lexists("/usr/" + rel):
        return "dep-view", []
    parts = rel.split("/")
    for i in range(len(parts) - 1, 0, -1):
        a = "/".join(parts[:i])
        if a in downers:
            o = downers[a]
            if me in o:
                return "missing-self", [me]
            return "missing", sorted(o)
    return "dangling", []


def elf_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    try:
        shoff, = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        secs = []
        for i in range(shnum):
            nm, typ, flags, addr, off, size = struct.unpack_from("<IIQQQQ", data, shoff + i * shentsize)
            secs.append([nm, typ, off, size])
        so = secs[shstrndx][2]
        out = []
        for nm, typ, off, size in secs:
            e = data.index(b"\0", so + nm)
            out.append((data[so + nm:e].decode(), typ, off, size))
        # runpath/interp string ranges
        special = []
        dyn = [s for s in out if s[0] == ".dynamic"]
        dstr = [s for s in out if s[0] == ".dynstr"]
        if dyn and dstr:
            _, _, doff, dsz = dyn[0]
            for k in range(0, dsz, 16):
                tag, val = struct.unpack_from("<qQ", data, doff + k)
                if tag in (15, 29):
                    s = dstr[0][2] + val
                    special.append((s, data.index(b"\0", s), "RUNPATH" if tag == 29 else "RPATH"))
        return out, special
    except Exception:
        return None


def context(data, off, elf):
    if elf is None:
        return "binary" if b"\0" in data[:8192] else "text"
    secs, special = elf
    for s, e, what in special:
        if s <= off < e:
            return "elf:" + what
    for nm, typ, so, sz in secs:
        if typ != 8 and so <= off < so + sz and nm:
            return "elf:" + nm
    return "elf:?"


refs = []            # (pkg, file, ctx, kind, owners, rel)
fhs = collections.Counter()
fhs_files = collections.defaultdict(set)
leaks = collections.Counter()
STORE = re.compile(rb"/nix/store/([a-z0-9]{32})-([A-Za-z0-9+._?=-]*)")
FHSRE = re.compile(rb"(?<![A-Za-z0-9._+\-])/usr/[A-Za-z0-9._+\-]+(?:/[A-Za-z0-9._+\-]+)?")


def scan(n, path, data, ctxhint=None):
    elf = elf_sections(data) if ctxhint is None else None
    i = data.find(Pb)
    while i >= 0:
        m = PATHCH.match(data, i + len(Pb))
        rel = norm(m.group(0))
        kind, owners = resolve(rel, n)
        refs.append((n, path, ctxhint or context(data, i, elf), kind, owners, rel))
        i = data.find(Pb, i + len(Pb))
    for m in STORE.finditer(data):
        if m.group(0).startswith(Pb[:len(m.group(0))]) or Pb.startswith(m.group(0)[:44]):
            continue
        leaks[m.group(2).decode(errors="replace")] += 1
    for m in FHSRE.finditer(data):
        s = m.group(0).decode(errors="replace")
        ln_start = data.rfind(b"\n", 0, m.start()) + 1
        shebang = data[ln_start:ln_start + 2] == b"#!" and ln_start == 0
        k = ("shebang " if shebang else "") + (ctxhint or ("elf" if elf else ("binary" if b"\0" in data[:8192] else "text"))) + " " + s
        fhs[k] += 1
        fhs_files[k].add(n + ":" + path)


for n, pk in pkgs.items():
    for fe in pk["files"]:
        p = pk["dir"] + fe["path"]
        if os.path.islink(p):
            t = os.readlink(p).encode()
            if Pb in t:
                scan(n, fe["path"], t, "symlink")
            elif t.startswith(b"/"):
                fhs["symlink-abs " + t.decode(errors="replace")[:60]] += 1
            continue
        if not os.path.isfile(p):
            continue
        with open(p, "rb") as fh:
            data = fh.read()
        scan(n, fe["path"], data)
        if fe["path"].endswith(".gz"):
            try:
                scan(n, fe["path"], gzip.decompress(data), "gzip")
            except Exception:
                pass

# graph + SCC
edges = collections.defaultdict(set)
kinds = collections.Counter()
ctxs = collections.Counter()
cross = []
for n, path, ctx, kind, owners, rel in refs:
    kinds[kind] += 1
    ctxs[ctx.split(":")[0] + (":" + ctx.split(":")[1] if ctx.startswith("elf:") and ctx.split(":")[1] in (".interp", "RUNPATH", "RPATH", ".rodata", ".dynstr") else "")] += 1
    if kind in ("file", "dir", "missing"):
        for o in owners:
            if o != n:
                edges[n].add(o)
                cross.append({"from": n, "to": o, "file": path, "ctx": ctx, "kind": kind, "rel": rel})
    if kind == "split-dir":
        cross.append({"from": n, "to": "|".join(owners), "file": path, "ctx": ctx, "kind": kind, "rel": rel})


def tarjan(nodes, edges):
    idx, low, st, on, res, c = {}, {}, [], set(), [], [0]
    def sc(v):
        idx[v] = low[v] = c[0]; c[0] += 1; st.append(v); on.add(v)
        for w in edges.get(v, ()):
            if w not in idx:
                sc(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], idx[w])
        if low[v] == idx[v]:
            comp = []
            while True:
                w = st.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            res.append(sorted(comp))
    for v in nodes:
        if v not in idx:
            sc(v)
    return res


sys.setrecursionlimit(10000)
sccs = [s for s in tarjan(sorted(pkgs), edges) if len(s) > 1]
res = {
    "P": P,
    "packages": {n: {"file": pk["file"], "nfiles": len(pk["files"]), "placement": placement_by_pkg[n]} for n, pk in pkgs.items()},
    "placement": dict(placement),
    "ref_kinds": dict(kinds),
    "ref_contexts": dict(ctxs),
    "edges": {k: sorted(v) for k, v in edges.items()},
    "sccs": sccs,
    "cross_refs_sample": cross[:400],
    "split_dir_refs": sorted({(c["from"], c["rel"], c["ctx"]) for c in cross if c["kind"] == "split-dir"})[:200],
    "dangling": sorted({(n, rel, ctx) for n, path, ctx, kind, owners, rel in refs if kind == "dangling"})[:200],
    "dep_view": sorted({(n, rel, ctx) for n, path, ctx, kind, owners, rel in refs if kind == "dep-view"})[:200],
    "fhs_refs": dict(fhs.most_common(300)),
    "fhs_ref_examples": {k: sorted(v)[:3] for k, v in list(fhs_files.items())[:300]},
    "foreign_store_refs": dict(leaks.most_common(50)),
}
with open(os.path.join(outdir, "analysis.json"), "w") as f:
    json.dump(res, f, indent=1, default=list)
print("packages:", len(pkgs), "placement:", dict(placement))
print("P refs:", sum(kinds.values()), dict(kinds))
print("contexts:", dict(ctxs))
print("edges:", {k: sorted(v) for k, v in edges.items()})
print("SCCs:", sccs)
print("foreign store refs:", dict(leaks.most_common(10)))
print("FHS /usr refs (top):")
for k, v in fhs.most_common(25):
    print("  %5d %s" % (v, k))
