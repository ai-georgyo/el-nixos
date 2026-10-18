#!/usr/bin/env python3
"""Prototype of the generic %files-driven output splitter + relocation linker.

usage: split.py --rpms DIR --prefix P --outputs JSON [--interp PATH] [--libdir DIR]... --report FILE

  --outputs  JSON {"<rpm %{NAME}>": "<nix output path>"}; every non-debug RPM
             built must be listed (static subpackage list), extra outputs stay empty
  --interp   PT_INTERP to set on ELF files whose interpreter is the FHS
             /lib64/ld-linux-x86-64.so.2 (i.e. linked by the FHS toolchain)
  --libdir   library dirs of dependency outputs, for RUNPATH resolution

Algorithm:
 1. extract each RPM; map payload paths into the output of its subpackage:
    P/<rel> and /usr/<rel> (and usrmove /lib64,/bin,..) -> $out_k/<rel>;
    FHS state (/etc, /var, /run, ...) -> $out_k/<path>, listed in nix-support.
 2. every occurrence of P in every file / symlink target is replaced by the
    path of the output that owns the referenced file (longest match), padded
    with '/' to len(P): length preserving, so ELF/.pyc/... stay intact.
    A reference becomes a Nix reference (hard edge) only if the referencing
    subpackage Requires the owner (rpm metadata); otherwise it is "soft" and
    rewritten to the referencing output itself (dangles harmlessly, like on
    an rpm system where the optional package is not installed).
 3. ELF: interpreter fix-up (FHS -> --interp), RUNPATH from DT_NEEDED
    (own outputs first, then --libdir), with patchelf.
 4. checks: no P left anywhere, no reference cycle between outputs.
"""
import argparse, collections, gzip, json, os, re, shutil, struct, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--rpms", required=True)
ap.add_argument("--prefix", required=True)
ap.add_argument("--outputs", required=True)
ap.add_argument("--interp")
ap.add_argument("--libdir", action="append", default=[])
ap.add_argument("--report", required=True)
ap.add_argument("--work", default=os.environ.get("TMPDIR", "/tmp") + "/split")
a = ap.parse_args()
P = a.prefix
Pb = P.encode()
outs = json.load(open(a.outputs))
for n, o in outs.items():
    assert len(o) <= len(P), "output path longer than P: %s" % o
FHS_TOP = ("etc", "var", "run", "boot", "opt", "srv", "root", "home", "tmp")
USRMOVE = ("bin", "sbin", "lib", "lib64")
PATHCH = re.compile(rb"[A-Za-z0-9._+\-/@%~,=]*")
PADCH = b"x"                      # the spike's P ends with 32 'x' (padding)
PADLEN = len(P) - len(P.rstrip("x"))
FRAGS = [P.encode()[:11 + 32 + 8], b"x" * 16]   # fragments of P that must not survive


def rpmq(f, *args):
    return subprocess.run(["rpm", "-qp", "--nosignature", "--nodigest", *args, f],
                          check=True, capture_output=True).stdout.decode("utf-8", "surrogateescape")


def canon(path):
    if path == P or path.startswith(P + "/"):
        return "P", path[len(P):].strip("/")
    top, _, rest = path.lstrip("/").partition("/")
    if top == "usr":
        return "P", rest
    if top in USRMOVE:
        return "P", (top + "/" + rest).strip("/")
    return "FHS", path.lstrip("/")


# ---------------------------------------------------------------- 1. extract + place
pk = {}
os.makedirs(a.work, exist_ok=True)
for arch in sorted(os.listdir(a.rpms)):
    for fn in sorted(os.listdir(os.path.join(a.rpms, arch))):
        f = os.path.join(a.rpms, arch, fn)
        name = rpmq(f, "--qf", "%{NAME}")
        if name.endswith("-debuginfo") or name.endswith("-debugsource"):
            continue  # prototype: debug outputs not handled here
        if name not in outs:
            sys.exit("split: subpackage %s built but not declared as an output (static list out of date)" % name)
        d = os.path.join(a.work, name)
        os.makedirs(d)
        subprocess.run("rpm2cpio '%s' | (cd '%s' && cpio -idm --quiet --no-absolute-filenames)" % (f, d),
                       shell=True, check=True)
        lst = rpmq(f, "--qf", "[%{FILENAMES}\t%{FILEFLAGS:fflags}\t%{FILEMODES:perms}\n]")
        files = [dict(zip(("path", "flags", "mode"), l.split("\t"))) for l in lst.splitlines() if l]
        req = set(l.split()[0] for l in rpmq(f, "--requires").splitlines() if l)
        prov = set(l.split()[0] for l in rpmq(f, "--provides").splitlines() if l)
        pk[name] = {"dir": d, "files": files, "requires": req, "provides": prov | {name}}

fowners = collections.defaultdict(set)
downers = collections.defaultdict(set)
placed = []  # (pkg, src, dst, rel-or-None)
fhs_manifest = collections.defaultdict(list)
for n, p in pk.items():
    for fe in p["files"]:
        sp, rel = canon(fe["path"])
        src = p["dir"] + fe["path"]
        if not os.path.lexists(src):
            continue  # %ghost
        dst = outs[n] + "/" + rel if rel else outs[n]
        placed.append((n, src, dst))
        if sp == "FHS":
            fhs_manifest[n].append({"path": fe["path"], "store": dst, "flags": fe["flags"], "mode": fe["mode"]})
            continue
        if fe["mode"].startswith("d"):
            downers[rel].add(n)
        else:
            fowners[rel].add(n)
        parts = rel.split("/")
        for i in range(len(parts)):
            downers["/".join(parts[:i])].add(n)


def requires(me, other):
    """does subpackage `me` Require something that only `other` provides?
    (a virtual provide with several providers -- glibc's "glibc-langpack" --
    is a choice, not a reference target)"""
    pv = pk[other]["provides"]
    for r in pk[me]["requires"]:
        if r in pv and sum(1 for q in pk.values() if r in q["provides"]) == 1:
            return True
    # file requires (/usr/bin/foo) against other's files
    for r in pk[me]["requires"]:
        if r.startswith("/"):
            sp, rel = canon(r)
            if rel in fowners and other in fowners[rel]:
                return True
    return False


main = None
edges = collections.defaultdict(set)
stats = collections.Counter()
soft = collections.Counter()
why = collections.defaultdict(set)
weak_seen, weak_ok = set(), set()


def resolve(rel, me):
    """-> (owner, kind)"""
    if rel == "":
        return me, "bare"
    cands, kind = None, None
    if rel in fowners:
        cands, kind = fowners[rel], "file"
    elif rel in downers:
        cands, kind = downers[rel], "dir"
    else:
        parts = rel.split("/")
        for i in range(len(parts) - 1, 0, -1):
            anc = "/".join(parts[:i])
            if anc in downers:
                cands, kind = downers[anc], "missing"
                break
    if not cands:
        return me, "dangling"
    if me in cands:
        return me, "self-" + kind
    if kind != "file" and len(cands) > 1:
        # a directory filled by several subpackages is a union (locale dirs,
        # gconv, terminfo).  If me Requires exactly one of the owners (the
        # "primary" one: ncurses-libs -> ncurses-base) that is a *weak* edge,
        # kept only if it does not close a cycle; the rest of the union is
        # composed at runtime (LOCPATH, GCONV_PATH, TERMINFO_DIRS, profiles)
        req = sorted(c for c in cands if requires(me, c))
        if len(req) == 1:
            weak_seen.add((me, req[0]))
            if (me, req[0]) in weak_ok:
                return req[0], "union-primary-" + kind
        soft[(me, rel, "union:" + ",".join(sorted(cands))[:120])] += 1
        return me, "union-" + kind
    req = sorted(c for c in cands if requires(me, c))
    if req:
        return req[0], kind
    soft[(me, rel, "->" + ",".join(sorted(cands))[:120])] += 1
    return me, "soft-" + kind


def rewrite_bytes(data, me):
    out = bytearray(data)
    i = data.find(Pb)
    n = 0
    while i >= 0:
        j = i + len(Pb)
        # store-by-pieces: gcc (x86-64-v3) materializes long string constants
        # with 32-byte vector chunks + an overlapping tail chunk; when the
        # chunks are adjacent the tail shows up as P + <end of P's padding> +
        # <suffix>.  Treat the padding run as the overlapped tail of the same
        # string: rel follows it, and the run is rewritten to the bytes the new
        # string has at those positions.
        k = 0
        while j + k < len(data) and data[j + k:j + k + 1] == PADCH and k < PADLEN:
            k += 1
        m = PATHCH.match(data, j + k)
        rel = re.sub(r"/+", "/", m.group(0).decode("utf-8", "surrogateescape")).strip("/")
        rel = re.sub(r"(^|/)\./", r"\1", rel)
        owner, kind = resolve(rel, me)
        stats[kind] += 1
        if k:
            stats["overlapped-tail"] += 1
        if owner != me:
            edges[me].add(owner)
            why[(me, owner)].add(rel + " (" + kind + ")")
        o = outs[owner].encode()
        repl = o + b"/" * (len(Pb) - len(o))
        out[i:j] = repl
        if k:
            out[j:j + k] = repl[len(repl) - k:]
        n += 1
        i = data.find(Pb, j + k)
    # (c) remaining fragments: a truncated/split head of P ("/nix/store/<H0>-...")
    #     or a tail chunk that starts inside P's padding.  The owning string is
    #     unknown, so map byte-for-byte by offset to *this* output's
    #     replacement (padding positions are '/' for every output).
    data2 = bytes(out)
    rself = outs[me].encode()
    rself = rself + b"/" * (len(Pb) - len(rself))
    head = Pb[:11 + 32 + 8]            # "/nix/store/" + H0 + 8 more bytes
    i = data2.find(head)
    while i >= 0:
        k = 0
        while i + k < len(data2) and k < len(Pb) and data2[i + k] == Pb[k]:
            k += 1
        out[i:i + k] = rself[:k]
        stats["fragment-head"] += 1
        n += 1
        i = data2.find(head, i + k)
    data2 = bytes(out)
    for mm in re.finditer(rb"x{8,}(?=/)", data2):
        a_, b_ = mm.span()
        if b_ - a_ <= len(Pb) - max(len(o) for o in outs.values()) or rself.endswith(b"/" * (b_ - a_)):
            out[a_:b_] = b"/" * (b_ - a_)
            stats["fragment-tail"] += 1
            n += 1
    return bytes(out), n


def canon_dst(dst, n):
    o = outs[n]
    if dst.startswith(o + "/"):
        rel = dst[len(o) + 1:]
        top = rel.split("/", 1)[0]
        if top in FHS_TOP:
            return "FHS", None
        return "P", rel
    return None, None


# ---------------------------------------------------------------- 1b. weak edges
# dry run over all files to learn the strong edges and the weak candidates,
# then admit weak edges (primary owner of a union dir) that keep the graph acyclic
for n_, src_, dst_ in placed:
    if os.path.isfile(src_) and not os.path.islink(src_):
        with open(src_, "rb") as fh:
            rewrite_bytes(fh.read(), n_)
strong = {k: set(v) for k, v in edges.items()}
def reach(a_, b_, g):
    st_, seen_ = [a_], set()
    while st_:
        x = st_.pop()
        if x == b_:
            return True
        if x in seen_:
            continue
        seen_.add(x)
        st_.extend(g.get(x, ()))
    return False
g = {k: set(v) for k, v in strong.items()}
for (x, y) in sorted(weak_seen):
    if not reach(y, x, g):
        weak_ok.add((x, y)); g.setdefault(x, set()).add(y)
edges.clear(); stats.clear(); soft.clear(); why.clear()

# ---------------------------------------------------------------- 2. copy + rewrite
rewritten = collections.Counter()
for n, src, dst in placed:
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.islink(src):
        t = os.readlink(src).encode()
        t2, k = rewrite_bytes(t, n)
        if k:
            rewritten["symlink"] += 1
        else:
            # relative (or FHS-absolute) symlinks that cross subpackages: on
            # rpm systems they resolve in the shared /usr; split into store
            # paths they must point at the owning output explicitly
            tt = t.decode("utf-8", "surrogateescape")
            sp_, srel = canon_dst(dst, n)
            if srel is not None:
                if tt.startswith("/"):
                    tsp, trel = canon(tt)
                    trel = trel if tsp == "P" else None
                else:
                    trel = os.path.normpath(os.path.join(os.path.dirname(srel), tt)).lstrip("/")
                    trel = None if trel.startswith("..") else trel
                if trel is not None and trel not in (k_ for k_ in () ) and not (n in fowners.get(trel, ()) or n in downers.get(trel, ())):
                    owner, kind = resolve(trel, n)
                    stats["symlink-" + kind] += 1
                    if owner != n:
                        edges[n].add(owner)
                        t2 = (outs[owner] + "/" + trel).encode()
                        rewritten["symlink-cross"] += 1
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(t2.decode("utf-8", "surrogateescape"), dst)
    elif os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
    else:
        with open(src, "rb") as fh:
            data = fh.read()
        data2, k = rewrite_bytes(data, n)
        if src.endswith(".gz") and k == 0:
            try:
                raw = gzip.decompress(data)
                raw2, k2 = rewrite_bytes(raw, n)
                if k2:
                    data2 = gzip.compress(raw2, compresslevel=9, mtime=0)
                    rewritten["gzip"] += 1
            except Exception:
                pass
        if k:
            rewritten["file"] += 1
        with open(dst, "wb") as fh:
            fh.write(data2)
        shutil.copymode(src, dst)
for n in outs:
    os.makedirs(outs[n], exist_ok=True)

# ---------------------------------------------------------------- 3. ELF fix-ups
def elf_info(path):
    with open(path, "rb") as fh:
        h = fh.read(64)
    if h[:4] != b"\x7fELF":
        return None
    r = subprocess.run(["patchelf", "--print-interpreter", path], capture_output=True, text=True)
    interp = r.stdout.strip() if r.returncode == 0 else None
    r = subprocess.run(["patchelf", "--print-needed", path], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    needed = r.stdout.split()
    r = subprocess.run(["patchelf", "--print-rpath", path], capture_output=True, text=True)
    return interp, needed, r.stdout.strip()


libdirs_own = sorted({os.path.dirname(dst) for n, src, dst in placed
                      if re.search(r"/lib(64)?/[^/]*\.so[.0-9]*$", dst)})
elf_fix = collections.Counter()
unresolved = collections.Counter()
for n, src, dst in placed:
    if os.path.islink(dst) or not os.path.isfile(dst):
        continue
    info = elf_info(dst)
    if not info:
        continue
    interp, needed, rpath = info
    os.chmod(dst, os.stat(dst).st_mode | 0o200)
    if interp == "/lib64/ld-linux-x86-64.so.2" and a.interp:
        subprocess.run(["patchelf", "--set-interpreter", a.interp, dst], check=True)
        elf_fix["interp"] += 1
    want = []
    ldir = os.path.dirname(a.interp) if a.interp else None
    mine = [d for d in libdirs_own if d.startswith(outs[n] + "/")]
    reqd = [d for d in libdirs_own if not d.startswith(outs[n] + "/") and any(
        d.startswith(outs[o] + "/") and o in pk and o != n and requires(n, o) for o in outs)]
    for so in needed:
        if ldir and os.path.exists(os.path.join(ldir, so)):
            continue  # default search dir of the dynamic linker
        for d in mine + reqd + a.libdir:
            if os.path.exists(os.path.join(d, so)):
                if d not in want:
                    want.append(d)
                break
        else:
            unresolved[so] += 1
    cur = [x for x in rpath.split(":") if x]
    keep = [x for x in cur if x.startswith("$ORIGIN")]
    new = ":".join(keep + want)
    if new != rpath and (want or cur):
        subprocess.run(["patchelf", "--set-rpath", new, dst], check=True)
        elf_fix["runpath"] += 1
        for d in want:
            for o in outs.values():
                if d.startswith(o + "/"):
                    owner = [k for k, v in outs.items() if v == o][0]
                    if owner != n:
                        edges[n].add(owner)

# ---------------------------------------------------------------- 4. checks + metadata
left = []
frags = collections.Counter()
for n, src, dst in placed:
    if os.path.isfile(dst) and not os.path.islink(dst):
        with open(dst, "rb") as fh:
            d_ = fh.read()
            if Pb in d_:
                left.append(dst)
            for fr in FRAGS:
                if fr in d_:
                    frags[dst.split("/", 4)[-1]] += d_.count(fr)


def sccs(nodes):
    idx, low, st, on, res, c = {}, {}, [], set(), [], [0]
    sys.setrecursionlimit(100000)
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
    return [x for x in res if len(x) > 1]


cyc = sccs(sorted(outs))
for n in outs:
    ns = os.path.join(outs[n], "nix-support")
    os.makedirs(ns, exist_ok=True)
    meta = {"rpm": n, "requires": sorted(pk[n]["requires"]) if n in pk else [],
            "provides": sorted(pk[n]["provides"]) if n in pk else [],
            "fhs": fhs_manifest.get(n, []), "built": n in pk}
    with open(os.path.join(ns, "rocky-rpm.json"), "w") as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)
rep = {"P": P, "outputs": len(outs), "built": len(pk), "ref_kinds": dict(stats), "rewritten": dict(rewritten),
       "elf_fixups": dict(elf_fix), "unresolved_needed": dict(unresolved), "edges": {k: sorted(v) for k, v in sorted(edges.items())}, "cycles": cyc,
       "soft_refs": [list(k) + [v] for k, v in sorted(soft.items())][:500], "p_left": left[:50],
       "p_fragments_left": dict(frags.most_common(100)),
       "weak_edges_admitted": sorted("%s -> %s" % e for e in weak_ok),
       "weak_edges_dropped": sorted("%s -> %s" % e for e in weak_seen - weak_ok),
       "edge_reasons": {"%s -> %s" % k: sorted(v)[:20] for k, v in sorted(why.items())}}
with open(a.report, "w") as fh:
    json.dump(rep, fh, indent=1)
print(json.dumps({k: rep[k] for k in ("built", "ref_kinds", "rewritten", "elf_fixups", "unresolved_needed", "cycles", "p_fragments_left")}, indent=1))
print("edges:", rep["edges"])
print("soft refs:", len(soft), "(first 15)")
for k in list(sorted(soft))[:15]:
    print("  ", k)
if left:
    sys.exit("split: placeholder left in %d files, e.g. %s" % (len(left), left[:3]))
if cyc:
    for c in cyc:
        for x in c:
            for y in c:
                if (x, y) in why:
                    print("  cycle edge %s -> %s: %s" % (x, y, sorted(why[(x, y)])[:10]))
    sys.exit("split: reference cycle(s) between outputs, merge them: %s" % cyc)
