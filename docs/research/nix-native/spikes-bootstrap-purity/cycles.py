#!/usr/bin/env python3
"""Spike 2: break the direct-BuildRequires SCC.
 - classify every direct BR edge by the binary package that satisfies it
   (lib = -devel/-libs/-static/pkgconfig/soname; doc; test; lang = big language
   toolchains; tool = everything else)
 - SCC sizes after dropping doc edges, doc+test edges (what --nocheck and
   bcond docs/tests would cut), and after dropping everything but lib edges
 - greedy feedback-arc set (Eades-Lin-Smyth) of the remaining graph, by class
 - bootstrap-layer view: SRPMs needed (transitively, direct graph) by the
   stdenv core
Usage: cycles.py <repo-root> <outdir>
"""
import collections, importlib.util, json, os, re, sys
sys.dont_write_bytecode = True
root, outdir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("rbr", os.path.join(root, "tools/resolve-buildrequires.py"))
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)
uni = R.Universe(os.path.join(root, "lock/rocky-10.2"))

DOC = re.compile(r"^(texlive|texinfo-tex|doxygen|python3-sphinx|python3-docutils|asciidoc|asciidoctor|rubygem-asciidoctor|xmlto|docbook|graphviz|help2man|groff|pandoc|gtk-doc|ronn|dblatex|linuxdoc|fop|python3-myst|python3-breathe|libxslt$|xsltproc|man-db|perl-Pod|sgml)")
TEST = re.compile(r"^(dejagnu|valgrind|gdb|gdb-headless|python3-(pytest|hypothesis|mock|tox|nose|testtools|coverage|pytest-.*)|check-devel|cmocka|gtest|gmock|CUnit|perl-Test-|junit|hamcrest|mockito|testng|assertj|opentest4j|xorg-x11-server-Xvfb|dbus-daemon|expect|tcl$|strace|lcov|libfaketime|openssl-perl|softhsm|nss-tools|socket_wrapper|uid_wrapper|nss_wrapper|resolv_wrapper|pam_wrapper|cppunit|catch|doctest|qt6-qttest|python3-pexpect|bats)")
LANG = re.compile(r"^(rust|cargo|rust-toolset|golang|go-|java-|javapackages|maven|ant$|ghc|ocaml|dotnet|nodejs|ruby|erlang|clang|llvm|lld|gcc-gnat|gcc-gfortran)")
LIB = re.compile(r"(-devel$|-static$|-libs$|^lib.*\.so|^pkgconfig\(|-headers$)")

def cls(binname):
    if DOC.search(binname): return "doc"
    if TEST.search(binname): return "test"
    if LANG.search(binname): return "lang"
    if LIB.search(binname): return "lib"
    return "tool"

edges = collections.defaultdict(dict)   # s -> t -> set(class)
for s in sorted(uni.srpms):
    r, _, br = R.resolve(uni, s, [])
    for dep, ks in br.items():
        for k in ks:
            t = uni.rpms[k]["srpm"]
            if t == s: continue
            edges[s].setdefault(t, set()).add(cls(uni.rpms[k]["name"]))

def tarjan(g, nodes):
    idx, low, on, st, out, n = {}, {}, set(), [], [], [0]
    sys.setrecursionlimit(100000)
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
            out.append(c)
    for v in nodes:
        if v not in idx: sc(v)
    return out

nodes = sorted(uni.srpms)
def graph(keep):
    # an edge survives if any of its classes is kept (one BR of that class suffices)
    return {s: [t for t, cs in ts.items() if cs & keep] for s, ts in edges.items()}

res = {}
for label, keep in [("all", {"doc", "test", "lang", "lib", "tool"}),
                    ("no-doc", {"test", "lang", "lib", "tool"}),
                    ("no-doc-test", {"lang", "lib", "tool"}),
                    ("no-doc-test-lang", {"lib", "tool"}),
                    ("lib-only", {"lib"})]:
    g = graph(keep)
    sccs = sorted((c for c in tarjan(g, nodes) if len(c) > 1), key=len, reverse=True)
    res[label] = {"sizes": [len(c) for c in sccs][:10], "in_cycles": sum(len(c) for c in sccs),
                  "largest": sorted(sccs[0]) if sccs else []}
    print("%-17s SCC sizes %s  (SRPMs in cycles: %d)" % (label, res[label]["sizes"], res[label]["in_cycles"]))

# greedy FAS (Eades) on the no-doc-test graph's largest SCC
def eades(g, members):
    m = set(members)
    out = {v: set(w for w in g.get(v, ()) if w in m) for v in m}
    inn = {v: set() for v in m}
    for v in m:
        for w in out[v]: inn[w].add(v)
    s1, s2 = [], []
    alive = set(m)
    while alive:
        changed = True
        while changed:
            changed = False
            for v in [v for v in alive if not (out[v] & alive)]:
                alive.discard(v); s2.append(v); changed = True
            for v in [v for v in alive if not (inn[v] & alive)]:
                alive.discard(v); s1.append(v); changed = True
        if alive:
            v = max(alive, key=lambda x: (len(out[x] & alive) - len(inn[x] & alive), x))
            alive.discard(v); s1.append(v)
    order = s1 + s2[::-1]
    pos = {v: i for i, v in enumerate(order)}
    back = [(v, w) for v in m for w in out[v] if pos[w] < pos[v]]
    return order, back

for label, keep in [("all", {"doc", "test", "lang", "lib", "tool"}), ("no-doc-test", {"lang", "lib", "tool"})]:
    g = graph(keep)
    big = max(tarjan(g, nodes), key=len)
    order, back = eades(g, big)
    bycls = collections.Counter()
    for v, w in back:
        for c in edges[v][w] & keep: bycls[c] += 1
    tgt = collections.Counter(w for v, w in back)
    libsrc = sorted({v for v, w in back if "lib" in edges[v][w]})
    onlybuild = sorted({w for v, w in back if not (edges[v][w] & {"lib"})})
    res["fas-" + label + "-detail"] = {"distinct_targets": len(tgt), "srpms_with_lib_backedge": len(libsrc),
        "srpms_with_any_backedge": len({v for v, w in back}), "targets": sorted(tgt), "lib_backedge_srpms": libsrc}
    print("   distinct back-edge targets=%d; SRPMs with a back edge=%d; with a lib-class back edge=%d"
          % (len(tgt), len({v for v, w in back}), len(libsrc)))
    res["fas-" + label] = {"scc": len(big), "edges_in_scc": sum(1 for v in big for w in g[v] if w in set(big)),
                           "back_edges": len(back), "by_class": dict(bycls), "top_targets": tgt.most_common(25)}
    print("FAS %-12s scc=%d edges=%d back=%d by_class=%s" % (label, len(big), res["fas-" + label]["edges_in_scc"], len(back), dict(bycls)))
    print("   most-hit back-edge targets:", tgt.most_common(20))

# stdenv core: SRPMs reachable (direct graph, lib+tool, no doc/test/lang) from a toolchain seed
seed = ["glibc", "gcc", "binutils", "make", "coreutils", "bash", "sed", "grep", "gawk", "findutils",
        "diffutils", "patch", "tar", "gzip", "bzip2", "xz", "zstd", "cpio", "file", "rpm", "redhat-rpm-config",
        "debugedit", "elfutils", "dwz", "perl", "python3.12", "m4", "bison", "flex", "texinfo", "gettext", "pkgconf",
        "autoconf", "automake", "libtool", "util-linux", "which"]
seed = [s for s in seed if s in uni.srpms]
for label, keep in [("lib+tool", {"lib", "tool"}), ("lib+tool+lang", {"lib", "tool", "lang"})]:
    g = graph(keep)
    seen, todo = set(), list(seed)
    while todo:
        s = todo.pop()
        if s in seen: continue
        seen.add(s); todo += g.get(s, [])
    res["core-" + label] = sorted(seen)
    print("stdenv core closure (%s): %d SRPMs" % (label, len(seen)))
json.dump(res, open(os.path.join(outdir, "cycles.json"), "w"), indent=1)
