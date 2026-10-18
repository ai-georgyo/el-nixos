#!/usr/bin/env python3
"""Spike: quantify the SRPM BuildRequires graph of Rocky 10.2 (cycles, SCCs,
stdenv core), using tools/resolve-buildrequires.py as a library.

Graphs (edge S -> T: building S needs a binary package of SRPM T):
  mock   : mock-like closure (chroot_setup + BuildRequires, full Requires closure)
  br     : BuildRequires closure only (no chroot_setup), full Requires closure
  direct : only the direct providers of each BuildRequires (no Requires closure)
           -- the Nix-native view: runtime closure comes from references,
           and the stdenv (gcc/binutils/glibc-devel/make/coreutils/rpm-build ...)
           is implicit.
Usage: brgraph.py <repo-root> <outdir>
"""
import collections, importlib.util, json, os, sys, time
sys.dont_write_bytecode = True
root, outdir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("rbr", os.path.join(root, "tools/resolve-buildrequires.py"))
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)
uni = R.Universe(os.path.join(root, "lock/rocky-10.2"))
buildsys = R.MOCK_CHROOT_SETUP["rocky-10"].split()

def srpm_of(k): return uni.rpms[k]["srpm"]

t0 = time.time()
# buildsys closure (transaction 1 alone)
r0 = R.Resolver(uni); r0.install_names(buildsys, "@buildsys")
buildsys_pkgs = set(r0.selected)
buildsys_srpms = sorted({srpm_of(k) for k in buildsys_pkgs})

G = {"mock": {}, "br": {}, "direct": {}}
unres = {}
for s in sorted(uni.srpms):
    r, base, br_map = R.resolve(uni, s, buildsys)
    G["mock"][s] = sorted({srpm_of(k) for k in r.selected})
    if r.unresolved: unres[s] = sorted({d for d, _ in r.unresolved})
    r2, _, br2 = R.resolve(uni, s, [])
    G["br"][s] = sorted({srpm_of(k) for k in r2.selected})
    G["direct"][s] = sorted({srpm_of(k) for ks in br2.values() for k in ks})
t1 = time.time()

def tarjan(g):
    idx, low, on, st, out, n = {}, {}, set(), [], [], [0]
    sys.setrecursionlimit(100000)
    def sc(v):
        idx[v] = low[v] = n[0]; n[0] += 1; st.append(v); on.add(v)
        for w in g.get(v, ()):
            if w not in g: continue
            if w not in idx: sc(w); low[v] = min(low[v], low[w])
            elif w in on: low[v] = min(low[v], idx[w])
        if low[v] == idx[v]:
            c = []
            while True:
                w = st.pop(); on.discard(w); c.append(w)
                if w == v: break
            out.append(sorted(c))
    for v in g:
        if v not in idx: sc(v)
    return out

report = {"seconds": round(t1 - t0, 1), "srpms": len(uni.srpms),
          "buildsys_packages": len(buildsys_pkgs), "buildsys_srpms": buildsys_srpms,
          "unresolved_srpms": len(unres)}
for name, g in G.items():
    selfloops = sorted(s for s, ts in g.items() if s in ts)
    sccs = tarjan(g)
    big = sorted((c for c in sccs if len(c) > 1), key=len, reverse=True)
    deg = [len([t for t in ts if t != s]) for s, ts in g.items()]
    report[name] = {
        "edges": sum(deg), "mean_deps": round(sum(deg) / len(deg), 1),
        "max_deps": max(deg),
        "selfloops": len(selfloops), "selfloop_srpms": selfloops,
        "nontrivial_sccs": len(big), "scc_sizes": [len(c) for c in big][:20],
        "largest_scc": big[0] if big else [],
        "acyclic_srpms": sum(1 for c in sccs if len(c) == 1 and c[0] not in selfloops),
    }
json.dump(report, open(os.path.join(outdir, "brgraph.json"), "w"), indent=1)
json.dump(G, open(os.path.join(outdir, "brgraph-edges.json"), "w"))
for name in G:
    x = report[name]
    print("%-6s edges=%d mean=%.1f max=%d selfloops=%d sccs>1=%d sizes=%s acyclic=%d"
          % (name, x["edges"], x["mean_deps"], x["max_deps"], x["selfloops"], x["nontrivial_sccs"],
             x["scc_sizes"][:8], x["acyclic_srpms"]))
print("buildsys: %d packages from %d SRPMs; %.0fs; unresolved in %d SRPMs"
      % (len(buildsys_pkgs), len(buildsys_srpms), t1 - t0, len(unres)))
