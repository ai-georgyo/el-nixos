#!/usr/bin/env python3
"""Spike: which FHS paths are compiled into / written in the files of each
glibc subpackage, and which subpackage owns the target.  In a relocated build
every such string becomes a store path of the owning output, i.e. a Nix
reference between outputs.  Prints the inter-subpackage reference graph, its
SCCs, and the paths that point outside glibc (other SRPMs or runtime FHS).

Usage: xrefs.py <trees-linkfarm> <outdir>
"""
import collections, json, os, re, sys
trees, outdir = sys.argv[1], sys.argv[2]
ROOTS = (b"/usr/", b"/etc/", b"/var/", b"/lib64/", b"/lib/", b"/run/", b"/sbin/", b"/bin/")
pat = re.compile(rb"(?<![A-Za-z0-9_.\-/])(/(?:usr|etc|var|lib64|lib|run|sbin|bin)(?:/[A-Za-z0-9_.+@%\-]+)*/?)")

owner = {}       # path -> set(subpkg)
dirs = collections.defaultdict(set)
files = []
for sp in sorted(os.listdir(trees)):
    base = os.path.realpath(os.path.join(trees, sp))
    for dp, dn, fn in os.walk(base):
        rel = dp[len(base):] or "/"
        dirs[rel].add(sp)
        for f in fn:
            p = os.path.join(rel, f)
            owner.setdefault(p, set()).add(sp)
            files.append((sp, os.path.join(dp, f), p))
        for d in dn:
            if os.path.islink(os.path.join(dp, d)):
                owner.setdefault(os.path.join(rel, d), set()).add(sp)

def usrmove(p):
    for a, b in (("/lib64/", "/usr/lib64/"), ("/lib/", "/usr/lib/"), ("/bin/", "/usr/bin/"), ("/sbin/", "/usr/sbin/")):
        if p.startswith(a): return b + p[len(a):]
    return p

def resolve(p):
    """owning subpackages of path p, or of its longest existing prefix"""
    q = usrmove(p.rstrip("/")) or "/"
    # exact file/symlink, or a directory owned by exactly one subpackage
    # (printf-style templates like /usr/share/locale/%L/%N: strip the % parts)
    while "%" in q: q = os.path.dirname(q)
    if q in owner: return owner[q], q
    while q and q != "/":
        if q in dirs and len(dirs[q]) == 1: return dirs[q], q + "/"
        if q in owner: return owner[q], q
        if q in dirs: return set(), None   # shared dir: not a reference to anyone in particular
        q = os.path.dirname(q)
    return set(), None

edges = collections.defaultdict(lambda: collections.defaultdict(set))
external = collections.defaultdict(set)
kinds = collections.Counter()
for sp, real, rel in files:
    if os.path.islink(real):
        data = os.readlink(real).encode(); kind = "symlink"
        if not data.startswith(b"/"): continue
    else:
        try:
            with open(real, "rb") as fh: data = fh.read()
        except OSError: continue
        kind = "elf" if data[:4] == b"\x7fELF" else ("ar" if data[:8] == b"!<arch>\n" else "other")
        if sp.startswith("glibc-langpack-") or "locale" in rel and kind == "other" and len(data) > 1 << 20:
            pass
    for m in set(pat.findall(data)):
        p = m.decode(errors="replace")
        if p in ("/usr/", "/etc/", "/var/", "/lib/", "/bin/", "/usr", "/lib64/"): continue
        if os.environ.get("FHS_RUNTIME") and p.startswith(("/etc", "/var", "/run")): continue
        own, hit = resolve(p)
        if own:
            for o in own:
                if o != sp:
                    edges[sp][o].add((p, rel, kind)); kinds[kind] += 1
        else:
            external[p].add(sp)

# graph + SCCs over subpackages (langpacks folded)
def fold(n): return "glibc-langpack-*" if n.startswith("glibc-langpack-") else n
g = collections.defaultdict(set)
for a, bs in edges.items():
    for b in bs:
        if fold(a) != fold(b): g[fold(a)].add(fold(b))
nodes = set(g) | {b for bs in g.values() for b in bs}
idx, low, on, st, sccs, n = {}, {}, set(), [], [], [0]
def sc(v):
    idx[v] = low[v] = n[0]; n[0] += 1; st.append(v); on.add(v)
    for w in g.get(v, ()):
        if w not in idx: sc(w); low[v] = min(low[v], low[w])
        elif w in on: low[v] = min(low[v], idx[w])
    if low[v] == idx[v]:
        c = []
        while True:
            w = st.pop(); on.discard(w); c.append(w)
            if w == v: break
        sccs.append(sorted(c))
for v in sorted(nodes):
    if v not in idx: sc(v)
big = [c for c in sccs if len(c) > 1]
out = {
    "edges": {fold(a) + " -> " + fold(b): sorted({"%s  (in %s, %s)" % x for x in v})[:12]
              for a, bs in sorted(edges.items()) for b, v in sorted(bs.items()) if fold(a) != fold(b)},
    "sccs": big,
    "external": {p: sorted(v)[:6] for p, v in sorted(external.items())},
}
json.dump(out, open(os.path.join(outdir, "glibc-xrefs.json"), "w"), indent=1)
print("subpackage graph: %d nodes, %d edges; SCCs>1: %s" % (len(nodes), sum(len(v) for v in g.values()), big))
for k in sorted(out["edges"]):
    print(k); [print("    " + x) for x in out["edges"][k][:5]]
print("paths owned by no glibc subpackage (%d):" % len(external))
for p in sorted(external):
    print("  %-50s %s" % (p, ",".join(sorted(external[p])[:4])))
