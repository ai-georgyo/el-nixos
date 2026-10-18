"""Phase H: the output reference graph as Nix will see it, cycles (Tarjan
SCC) with merge suggestions, merge report, late-binding set L* (design
§2.9, §3.3)."""
import collections
import fnmatch
import os

from . import elf as E
from . import scan as S
from .refs import walk_files


def nix_edges(ctx):
    """Y -> {X: (file, count)} from the final contents: Nix's own test (X's
    hash part anywhere in Y's files or symlink targets) + hidden-references"""
    hashes = {ctx.hash_of(ctx.out[o]).encode(): o for o in ctx.out}
    wanted = set(hashes)
    edges = collections.defaultdict(dict)
    for y in ctx.out:
        root = ctx.out[y]
        if not os.path.isdir(root):
            continue
        for d, dirs, files in os.walk(root):
            dirs.sort()
            for n in sorted(files) + sorted(x for x in dirs if os.path.islink(os.path.join(d, x))):
                p = os.path.join(d, n)
                if os.path.islink(p):
                    data = os.readlink(p).encode("utf-8", "surrogateescape")
                else:
                    with open(p, "rb") as f:
                        data = f.read()
                for h in S.hashes_in(data, wanted):
                    x = hashes[h]
                    if x == y:
                        continue
                    ev = edges[y].get(x)
                    edges[y][x] = (ev[0], ev[1] + 1) if ev else (os.path.relpath(p, root), 1)
    return edges


def tarjan(nodes, succ):
    """iterative Tarjan; -> list of SCCs (lists), reverse topological order"""
    index, low, onstack, stack, out = {}, {}, set(), [], []
    counter = [0]
    for root in nodes:
        if root in index:
            continue
        work = [(root, iter(sorted(succ.get(root, ()))))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        onstack.add(root)
        while work:
            v, it = work[-1]
            advanced = False
            for w in it:
                if w not in index:
                    index[w] = low[w] = counter[0]
                    counter[0] += 1
                    stack.append(w)
                    onstack.add(w)
                    work.append((w, iter(sorted(succ.get(w, ())))))
                    advanced = True
                    break
                if w in onstack:
                    low[v] = min(low[v], index[w])
            if advanced:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[v])
            if low[v] == index[v]:
                comp = []
                while True:
                    w = stack.pop()
                    onstack.discard(w)
                    comp.append(w)
                    if w == v:
                        break
                out.append(sorted(comp))
    return out


def check_graph(ctx, edges):
    rep = ctx.report
    nodes = list(ctx.out)
    succ = {y: set(xs) for y, xs in edges.items()}
    sccs = tarjan(nodes, succ)
    cycles = [c for c in sccs if len(c) > 1]
    subs_by_out = collections.defaultdict(list)
    for s, o in sorted(ctx.sub_output.items()):
        subs_by_out[o].append(s)
    prefix_sub = next((s for s in subs_by_out.get(ctx.prefix_output, [])), None)
    for c in cycles:
        members = [s for o in c for s in subs_by_out.get(o, [])]
        if prefix_sub in members:
            members.remove(prefix_sub)
            members.insert(0, prefix_sub)
        ev = {"%s->%s" % (y, x): list(edges[y][x]) for y in c for x in c if x in edges.get(y, {})}
        rep.error("cycle", "reference cycle between outputs %s; suggested: mergeOutputs = [ [ %s ] ] (evidence: %s)"
                  % (", ".join(c), " ".join('"%s"' % m for m in members),
                     "; ".join("%s %s" % (k, v[0]) for k, v in sorted(ev.items())[:6])),
                  outputs=c, suggestion=members, evidence=ev)
    special = [o for o in [ctx.debug_output] + sorted(ctx.unmanaged) if o]
    for y, xs in sorted(edges.items()):
        for x in special:
            if x in xs and y != x:
                rep.error("debug-referenced", "%s references %s (%s): nothing may reference %s"
                          % (y, x, xs[x][0], x), output=y, owner=x)
    rep.section("graph", {
        "edges": {y: {x: list(v) for x, v in sorted(xs.items())} for y, xs in sorted(edges.items())},
        "sccs": cycles,
    })
    return succ


def merges(ctx):
    """internal references of every mergeOutputs group (subpackage level)"""
    rep = ctx.report
    out = []
    for g in ctx.plan.mergeOutputs:
        refs = {"%s->%s" % (a, b): n for (a, b), n in sorted(ctx.subref.items()) if a in g and b in g}
        out.append({"group": g, "internalRefs": refs})
        if not refs:
            rep.info("merge-unneeded", "mergeOutputs group %s: no reference between its members was seen; the merge"
                     " may not be needed" % g, group=g)
    rep.section("merges", out)


def late(ctx, succ):
    """L* = L + every sibling output reaching L; verify lateReferrers and that
    no ELF content in L* references L (symlinks, text, RUNPATH only)."""
    rep, plan = ctx.report, ctx.plan
    L = [o for o in plan.lateBind if o in ctx.out]
    for o in plan.lateBind:
        if o not in ctx.out:
            rep.error("late-referrer-missing", "lateBind names %s, which is not an output" % o, output=o)
    if not L:
        return None
    pred = collections.defaultdict(set)
    for y, xs in succ.items():
        for x in xs:
            pred[x].add(y)
    # debug (and unmanaged outputs) may reference siblings and are not rebound
    skip = {o for o in [ctx.debug_output] + sorted(ctx.unmanaged) if o}
    reach = {}
    for l in L:
        seen, todo = set(skip), [l]
        while todo:
            v = todo.pop()
            for w in pred.get(v, ()):
                if w not in seen and w != l:
                    seen.add(w)
                    todo.append(w)
        reach[l] = seen - skip
    lstar = set(L)
    for l in L:
        lstar |= reach[l]
    used = set()
    for l in L:
        pats = plan.lateReferrers.get(l, [])
        for y in sorted(reach[l] - set(L)):
            m = next((p for p in pats if fnmatch.fnmatchcase(y, p)), None)
            if m is None:
                rep.error("late-referrer-missing", "%s reaches lateBind output %s but is not in lateReferrers.%s"
                          % (y, l, l), output=y, owner=l)
            else:
                used.add((l, m))
        for p in pats:
            if (l, p) not in used:
                rep.info("late-referrer-unused", "lateReferrers.%s: %s matched no referrer" % (l, p), owner=l)
    # ELF contents of L* referencing L (outside the RUNPATH string)
    lh = {ctx.hash_of(ctx.out[l]).encode(): l for l in L}
    for y in sorted(lstar):
        for rel, path in walk_files(ctx.out[y]):
            with open(path, "rb") as f:
                data = f.read()
            if data[:4] != b"\x7fELF":
                continue
            ef = E.parse(data)
            spans = ef.rpath_spans if ef else []
            for h, l in lh.items():
                if l == y:
                    continue
                i = data.find(h)
                while i >= 0:
                    if not any(a <= i < b for a, b in spans):
                        rep.error("late-elf-ref", "%s/%s: ELF content references lateBind output %s (only symlinks,"
                                  " text and RUNPATH can be rebound)" % (y, rel, l), output=y, file=rel, owner=l)
                        break
                    i = data.find(h, i + 1)
    doc = {"late": sorted(L), "lstar": sorted(lstar),
           "referrers": {l: sorted(reach[l] - set(L)) for l in L},
           "binds": {l: plan.lateBind[l] for l in L}}
    rep.section("late", doc)
    return doc
