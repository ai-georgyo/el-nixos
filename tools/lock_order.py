"""order.json: SRPM build order from builddeps.json (design §8.2, §8.3).

Helper module of tools/update-lock.py, and the checker behind
checks.nn-order; standard library only, no other tools/ module needed.

    python3 -I tools/lock_order.py [--lock lock] [--release 10.2]   # (re)write order.json
    python3 -I tools/lock_order.py --check LOCKDIR                   # verify, report on stdout

Graph: S -> T ("S needs T") when a direct provider of one of S's
BuildRequires (builddeps.json ``inputs``) is built from SRPM T; S -> S is a
self-loop.  Every edge carries the classes of the providers behind it:

    doc   documentation toolchains (texlive, sphinx, doxygen, ...)
    test  test-only deps (dejagnu, valgrind, gdb, pytest, perl-Test-*, ...)
    lang  big language toolchains (rust, golang, java, ghc, llvm, ...)
    lib   -devel/-libs/-static/-headers, or tagged "lib" (may leave references)
    macro rpm macro package (tagged "macro" only)
    tool  anything else (build-time only)

(doc/test/lang/lib name patterns from the bootstrap-purity spike cycles.py.)
The edges inside each strongly connected component are ordered by the
Eades-Lin-Smyth greedy feedback-arc heuristic, deterministically (ties by
name); edges pointing "forward" in the resulting build order are the back
edges, satisfied from an earlier stage (design §8.3).  Components are
emitted dependencies first (Kahn, ties by smallest member name).

Output (one SRPM per line):

    {"format": 1, "release",
     "srpms": {"<srpm>": {"index": <position in the build order>,
                          "level": <longest chain of non-back edges below it>,
                          "needs": {"<srpm>": ["lib", "tool", ...]},
                          "back": ["<srpm>", ...],     # needs that are back edges (incl. self)
                          "scc": <component id, only for members of a cycle>}},
     "sccs": [[members...]],      # non-trivial components, id = position
     "bootTargets": [...],        # every back-edge target (incl. self-loops)
     "secondPass": [...],         # SRPMs with a lib-class back edge to another SRPM
     "selfLoops": [...],
     "stats": {...}}

--check verifies order.json independently of `index`: needs equal
builddeps.json, the graph minus the back edges is acyclic (Kahn) and its
levels match, every non-back edge points dependencies-first, and the
summary fields (sccs, bootTargets, secondPass, selfLoops, stats, scc ids)
are exactly what needs/back imply (derived(), shared with compute()).
"""

import argparse
import heapq
import json
import os
import re
import sys

DOC = re.compile(r"^(texlive|texinfo-tex|doxygen|python3-sphinx|python3-docutils|asciidoc|asciidoctor|rubygem-asciidoctor|xmlto|docbook|graphviz|help2man|groff|pandoc|gtk-doc|ronn|dblatex|linuxdoc|fop|python3-myst|python3-breathe|libxslt$|xsltproc|man-db|perl-Pod|sgml)")
TEST = re.compile(r"^(dejagnu|valgrind|gdb|gdb-headless|python3-(pytest|hypothesis|mock|tox|nose|testtools|coverage|pytest-.*)|check-devel|cmocka|gtest|gmock|CUnit|perl-Test-|junit|hamcrest|mockito|testng|assertj|opentest4j|xorg-x11-server-Xvfb|dbus-daemon|expect|tcl$|strace|lcov|libfaketime|openssl-perl|softhsm|nss-tools|socket_wrapper|uid_wrapper|nss_wrapper|resolv_wrapper|pam_wrapper|cppunit|catch|doctest|qt6-qttest|python3-pexpect|bats)")
LANG = re.compile(r"^(rust|cargo|rust-toolset|golang|go-|java-|javapackages|maven|ant$|ghc|ocaml|dotnet|nodejs|ruby|erlang|clang|llvm|lld|gcc-gnat|gcc-gfortran)")
LIB = re.compile(r"(-devel$|-static$|-libs$|^lib.*\.so|^pkgconfig\(|-headers$)")


def edge_class(name, tags):
    if DOC.search(name):
        return "doc"
    if TEST.search(name):
        return "test"
    if LANG.search(name):
        return "lang"
    if LIB.search(name) or "lib" in tags:
        return "lib"
    if tags == ["macro"]:
        return "macro"
    return "tool"


def needs_graph(builddeps):
    """{srpm: {srpm: sorted classes}} from a builddeps document."""
    prov = builddeps["providers"]
    g = {}
    for s, ent in builddeps["srpms"].items():
        out = {}
        for n in ent["inputs"]:
            p = prov[n]
            out.setdefault(p["srpm"], set()).add(edge_class(n, p["tags"]))
        g[s] = {t: sorted(c) for t, c in out.items()}
    # providers from SRPMs that are not in the lock cannot be built: drop
    nodes = set(g)
    return {s: {t: c for t, c in ts.items() if t in nodes} for s, ts in g.items()}


def tarjan(nodes, succ):
    """Iterative Tarjan; nodes and successor lists are visited sorted, so
    the result is deterministic.  Returns components (sorted member lists)."""
    index, low, on, stack, comps = {}, {}, set(), [], []
    n = 0
    for root in nodes:
        if root in index:
            continue
        work = [(root, iter(succ[root]))]
        index[root] = low[root] = n
        n += 1
        stack.append(root)
        on.add(root)
        while work:
            v, it = work[-1]
            for w in it:
                if w not in index:
                    index[w] = low[w] = n
                    n += 1
                    stack.append(w)
                    on.add(w)
                    work.append((w, iter(succ[w])))
                    break
                if w in on:
                    low[v] = min(low[v], index[w])
            else:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[v])
                if low[v] == index[v]:
                    c = []
                    while True:
                        w = stack.pop()
                        on.discard(w)
                        c.append(w)
                        if w == v:
                            break
                    comps.append(sorted(c))
    return comps


def eades(members, succ):
    """Eades-Lin-Smyth on the subgraph `members` (self-loops ignored).
    Returns the vertex sequence s1 + reverse(s2): edges that point backward
    in it form the feedback-arc set.  Here edges mean "needs", so sinks
    (needing nothing in the set) end up last; the build order is the reverse."""
    m = set(members)
    out = {v: {w for w in succ[v] if w in m and w != v} for v in m}
    inn = {v: set() for v in m}
    for v in m:
        for w in out[v]:
            inn[w].add(v)
    outd = {v: len(out[v]) for v in m}
    ind = {v: len(inn[v]) for v in m}
    alive = set(m)
    s1, s2 = [], []

    def remove(v):
        alive.discard(v)
        for w in out[v]:
            if w in alive:
                ind[w] -= 1
        for u in inn[v]:
            if u in alive:
                outd[u] -= 1

    while alive:
        changed = True
        while changed:
            changed = False
            sinks = sorted(v for v in alive if outd[v] == 0)
            for v in sinks:
                remove(v)
                s2.append(v)
            sources = sorted(v for v in alive if ind[v] == 0)
            for v in sources:
                remove(v)
                s1.append(v)
            changed = bool(sinks or sources)
        if alive:
            v = max(alive, key=lambda x: (outd[x] - ind[x], x))
            remove(v)
            s1.append(v)
    return s1 + s2[::-1]


def compute(builddeps):
    g = needs_graph(builddeps)
    nodes = sorted(g)
    succ = {s: sorted(g[s]) for s in nodes}
    comps = tarjan(nodes, succ)
    comp_of = {v: i for i, c in enumerate(comps) for v in c}
    # condensation, dependencies first: comp A before comp B if B needs A
    cdeps = [set() for _ in comps]
    for s in nodes:
        for t in succ[s]:
            if comp_of[t] != comp_of[s]:
                cdeps[comp_of[s]].add(comp_of[t])
    rdeps = [set() for _ in comps]
    for a, ds in enumerate(cdeps):
        for b in ds:
            rdeps[b].add(a)
    pending = [len(ds) for ds in cdeps]
    heap = [(comps[i][0], i) for i in range(len(comps)) if pending[i] == 0]
    heapq.heapify(heap)
    order = []
    while heap:
        _, i = heapq.heappop(heap)
        c = comps[i]
        order.extend(c if len(c) == 1 else eades(c, succ)[::-1])
        for a in sorted(rdeps[i]):
            pending[a] -= 1
            if pending[a] == 0:
                heapq.heappush(heap, (comps[a][0], a))
    assert len(order) == len(nodes), "condensation is not a DAG?"
    pos = {s: i for i, s in enumerate(order)}
    back = {s: sorted(t for t in succ[s] if pos[t] >= pos[s]) for s in nodes}
    level = {}
    for s in order:
        level[s] = 1 + max((level[t] for t in succ[s] if t not in back[s]), default=-1)
    d = derived(g, back, level, comps)
    srpms = {}
    for s in nodes:
        e = {"index": pos[s], "level": level[s], "needs": g[s], "back": back[s]}
        if s in d["sccOf"]:
            e["scc"] = d["sccOf"][s]
        srpms[s] = e
    out = {"format": 1, "release": builddeps.get("release"), "srpms": srpms}
    out.update((k, d[k]) for k in DERIVED)
    return out


# the top-level fields that follow from needs/back/level and the components
DERIVED = ("sccs", "bootTargets", "secondPass", "selfLoops", "stats")


def derived(g, back, level, comps):
    """sccs (+ sccOf), bootTargets, secondPass, selfLoops and stats from
    the graph g ({s: {t: classes}}), the back edges, the levels and the
    strongly connected components.  Shared by compute() and check_docs()."""
    nodes = sorted(g)
    big = sorted((c for c in comps if len(c) > 1), key=lambda c: (-len(c), c[0]))
    self_loops = sorted(s for s in nodes if s in g[s])
    n_edges = sum(len(g[s]) for s in nodes)
    back_edges = [(s, t) for s in nodes for t in back[s]]
    nonself_back = [(s, t) for s, t in back_edges if s != t]
    second = sorted({s for s, t in nonself_back if "lib" in g[s][t]})
    by_class = {}
    for s, t in nonself_back:
        for c in g[s][t]:
            by_class[c] = by_class.get(c, 0) + 1
    stats = {
        "srpms": len(nodes),
        "edges": n_edges - len(self_loops),
        "selfLoops": len(self_loops),
        "nontrivialSccs": len(big),
        "sccSizes": [len(c) for c in big],
        "backEdges": len(nonself_back),
        "backEdgesByClass": by_class,
        "bootTargets": len({t for _s, t in back_edges}),
        "srpmsWithBackEdge": len({s for s, _t in nonself_back}),
        "secondPass": len(second),
        "levels": 1 + max(level.values(), default=-1),
    }
    return {
        "sccs": big,
        "sccOf": {v: i for i, c in enumerate(big) for v in c},
        "bootTargets": sorted({t for _s, t in back_edges}),
        "secondPass": second,
        "selfLoops": self_loops,
        "stats": stats,
    }


# --------------------------------------------------------------------------
# independent verification (checks.nn-order)
# --------------------------------------------------------------------------

def check(lockdir):
    """Verify LOCKDIR/order.json against builddeps.json and srpms.json;
    returns a list of error strings (empty = OK) and prints a short report."""
    def load(n):
        with open(os.path.join(lockdir, n)) as f:
            return json.load(f)
    return check_docs(load("srpms.json")["srpms"], load("builddeps.json"), load("order.json"))


def check_docs(srpms, bd, od, quiet=False):
    errs = []
    O = od["srpms"]
    if set(O) != set(srpms) or set(bd["srpms"]) != set(srpms):
        errs.append("SRPM sets differ: order %d, builddeps %d, srpms.json %d"
                    % (len(O), len(bd["srpms"]), len(srpms)))
    g = needs_graph(bd)
    for s in sorted(set(O) & set(g)):
        if O[s]["needs"] != g[s]:
            errs.append("%s: needs differ from builddeps.json (stale order.json?)" % s)
    idx = sorted(e["index"] for e in O.values())
    if idx != list(range(len(O))):
        errs.append("index is not a permutation of 0..%d" % (len(O) - 1))
    targets = set(od["bootTargets"])
    second = set(od["secondPass"])
    kept = {s: [] for s in O}
    for s in sorted(O):
        e = O[s]
        back = set(e["back"])
        if not back <= set(e["needs"]):
            errs.append("%s: back edges %s are not needs" % (s, sorted(back - set(e["needs"]))))
        for t, cls in sorted(e["needs"].items()):
            if t not in O:
                errs.append("%s needs unknown SRPM %s" % (s, t))
                continue
            if t in back:
                if t not in targets:
                    errs.append("back edge %s -> %s: target not in bootTargets" % (s, t))
                if O[t]["index"] < O[s]["index"]:
                    errs.append("back edge %s -> %s points backward in the order" % (s, t))
                if t != s and "lib" in cls and s not in second:
                    errs.append("%s has a lib back edge to %s but is not in secondPass" % (s, t))
            else:
                if t == s:
                    errs.append("self-loop %s not marked as a back edge" % s)
                elif O[t]["index"] >= O[s]["index"]:
                    errs.append("edge %s -> %s (not a back edge) is not ordered dependencies-first" % (s, t))
                kept[s].append(t)
    # acyclicity after back-edge removal, independently of `index` (Kahn)
    pending = {s: len(ts) for s, ts in kept.items()}
    users = {s: [] for s in kept}
    for s, ts in kept.items():
        for t in ts:
            users[t].append(s)
    ready = sorted(s for s, n in pending.items() if n == 0)
    done = 0
    level = {}
    while ready:
        s = ready.pop()
        done += 1
        level[s] = 1 + max((level[t] for t in kept[s]), default=-1)
        for u in users[s]:
            pending[u] -= 1
            if pending[u] == 0:
                ready.append(u)
    if done != len(kept):
        cyc = sorted(s for s, n in pending.items() if n > 0)
        errs.append("graph minus back edges is cyclic: %d SRPMs left, e.g. %s" % (len(cyc), cyc[:10]))
    else:
        bad = sorted(s for s in O if O[s]["level"] != level[s])
        if bad:
            errs.append("level differs for %d SRPMs, e.g. %s" % (len(bad), bad[:10]))
        # the summary lists must be exactly what needs/back imply (not just
        # contain it): WP6 generates the second pass etc. from them
        G = {s: {t: c for t, c in O[s]["needs"].items() if t in O} for s in O}
        nodes = sorted(G)
        d = derived(G, {s: sorted(set(O[s]["back"]) & set(G[s])) for s in nodes}, level,
                    tarjan(nodes, {s: sorted(G[s]) for s in nodes}))
        for k in DERIVED:
            if od.get(k) != d[k]:
                if isinstance(d[k], list) and isinstance(od.get(k), list):
                    have = {json.dumps(x) for x in od[k]}
                    want = {json.dumps(x) for x in d[k]}

                    def short(xs):
                        return [x if len(x) < 60 else x[:57] + "..." for x in sorted(xs)[:5]]
                    errs.append("%s differs from the graph: %d extra %s, %d missing %s"
                                % (k, len(have - want), short(have - want),
                                   len(want - have), short(want - have)))
                else:
                    errs.append("%s differs from the graph" % k)
        bad = sorted(s for s in O if O[s].get("scc") != d["sccOf"].get(s))
        if bad:
            errs.append("scc differs for %d SRPMs, e.g. %s" % (len(bad), bad[:10]))
    if quiet:
        return errs
    n_back = sum(len(e["back"]) for e in O.values())
    print("order.json: %d SRPMs, %d edges, %d back edges (incl. %d self-loops), "
          "%d boot targets, %d second-pass SRPMs, %d levels"
          % (len(O), sum(len(e["needs"]) for e in O.values()), n_back, len(od["selfLoops"]),
             len(targets), len(second), 1 + max((e["level"] for e in O.values()), default=-1)))
    for e in errs:
        print("ERROR " + e)
    print("result: %s" % ("OK" if not errs else "%d errors" % len(errs)))
    return errs


def selftest():
    """Toy graph: a -> b -> c -> a (a cycle), d -> d, e alone.  Returns the
    number of failures."""
    def bd(edges):
        prov, srpms = {}, {}
        for s, ts in edges.items():
            ins = []
            for t, kind in ts:
                n = t + ("-devel" if kind == "lib" else "")
                prov[n] = {"srpm": t, "arch": "x86_64", "tags": [kind]}
                ins.append(n)
            srpms[s] = {"buildRequires": {}, "inputs": sorted(ins)}
        return {"release": "test", "srpms": srpms, "providers": prov}
    b = bd({"a": [("b", "lib")], "b": [("c", "tool")], "c": [("a", "tool")],
            "d": [("d", "tool"), ("e", "lib")], "e": []})
    names = {n: {} for n in b["srpms"]}
    od = compute(b)
    bad = 0
    want = {"sccs": [["a", "b", "c"]], "selfLoops": ["d"]}
    for k, v in want.items():
        if od[k] != v:
            _err("FAIL lock_order %s = %r, want %r" % (k, od[k], v))
            bad += 1
    if od["stats"]["backEdges"] != 1 or check_docs(names, b, od, quiet=True):
        _err("FAIL lock_order: expected 1 back edge and a clean check: %r" % od["stats"])
        bad += 1
    # tampering must be caught: bogus or missing summary entries ...
    def tampered(f):
        t = json.loads(json.dumps(od))
        f(t)
        return t
    for what, f in [("extra secondPass", lambda t: t["secondPass"].append("zzz")),
                    ("extra bootTarget", lambda t: t["bootTargets"].append("e")),
                    ("empty selfLoops", lambda t: t["selfLoops"].clear()),
                    ("empty sccs", lambda t: t["sccs"].clear()),
                    ("scc removed", lambda t: t["srpms"]["a"].pop("scc")),
                    ("stats", lambda t: t["stats"].update(levels=99))]:
        if not check_docs(names, b, tampered(f), quiet=True):
            _err("FAIL lock_order: tampering (%s) not detected" % what)
            bad += 1
    # ... and dropping the back edge of the cycle
    s = next(x for x in "abc" if [t for t in od["srpms"][x]["back"] if t != x])
    od["srpms"][s]["back"] = []
    if not check_docs(names, b, od, quiet=True):
        _err("FAIL lock_order: removing back edge of %s not detected" % s)
        bad += 1
    return bad


def _err(msg):
    print(msg, file=sys.stderr, flush=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lock", default="lock")
    ap.add_argument("--release", default="10.2")
    ap.add_argument("--check", metavar="LOCKDIR", help="verify LOCKDIR/order.json and exit")
    args = ap.parse_args(argv)
    if args.check:
        return 1 if check(args.check) else 0
    # writing reuses update-lock.py's deterministic JSON layout
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("update_lock", os.path.join(here, "update-lock.py"))
    UL = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(UL)
    lockdir = os.path.join(args.lock, "rocky-%s" % args.release)
    with open(os.path.join(lockdir, "builddeps.json")) as f:
        doc = compute(json.load(f))
    p = os.path.join(lockdir, "order.json")
    UL.write_text(p, UL.dump_one_per_line(doc))
    UL.log("wrote %s: %s" % (p, json.dumps(doc["stats"], sort_keys=True)))
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main())
