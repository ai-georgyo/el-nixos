"""Phase I: per-output metadata and setup hooks (design §2.10).

  <o>/nix-support/rpm/<subpkg>.json   files (flags, modes, owners, caps,
                                      digests), deps, scriptlets, triggers
  <o>/nix-support/rpm-name            the subpackage name(s) of <o>
  <o>/nix-support/setup-hook          search-path exports (if any)
  <o>/nix-support/hidden-references   store paths Nix's scanner cannot see
  $out/nix-support/rocky-stubs        forwarding stubs ("rel target")
  $out/nix-support/rocky-late.json    L* (if lateBind)"""
import collections
import json
import os
import stat

from . import headers as H


def _dump(path, doc, prefix=None):
    """JSON; the compile prefix is written as /usr (the rpm namespace), so
    metadata never references an output (Nix would see an edge)"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = json.dumps(doc, indent=1, sort_keys=True) + "\n"
    if prefix:
        text = text.replace(prefix, "/usr")
    with open(path, "w") as f:
        f.write(text)


def write_metadata(ctx):
    by_sub = collections.defaultdict(list)
    for e in ctx.entries:
        by_sub[e.sub].append(e)
    names = collections.defaultdict(set)
    for s, o in ctx.sub_output.items():
        names[o].add(s)
        rec = ctx.subs[s]
        files = []
        for e in by_sub[s]:
            files.append({
                "path": e.hpath, "rel": e.rel, "namespace": e.ns,
                "flags": H.fflags(e.flags), "mode": "%o" % e.mode,
                "type": e.kind, "user": e.user, "group": e.group, "caps": e.caps or None,
                "digest": e.digest or None, "linkto": e.linkto or None, "size": e.size,
                "setid": bool(e.mode & (stat.S_ISUID | stat.S_ISGID)), "ghost": e.ghost,
                "config": bool(e.flags & 1),
            })
        doc = {k: rec[k] for k in ("name", "epoch", "version", "release", "arch", "sourcerpm", "summary",
                                   "license", "url", "requires", "provides", "conflicts", "obsoletes",
                                   "recommends", "suggests", "supplements", "enhances", "scriptlets",
                                   "triggers", "fileTriggers", "transFileTriggers")}
        doc["output"] = o
        doc["files"] = files
        doc["siblingRequires"] = sorted(ctx.sub_requires.get(s, ()))
        _dump(os.path.join(ctx.out[o], "nix-support", "rpm", s + ".json"), doc, ctx.P)
    for o in ctx.managed:
        d = os.path.join(ctx.out[o], "nix-support")
        os.makedirs(d, exist_ok=True)
        if names.get(o):
            with open(os.path.join(d, "rpm-name"), "w") as f:
                f.write("".join(n + "\n" for n in sorted(names[o])))


def write_hooks(ctx):
    """setup hooks for search paths: a directory -> addToSearchPath, a file ->
    export if unset (runtimeSearchPaths and searchPaths of the plan)"""
    table = dict(ctx.plan.searchPaths)
    table.update(ctx.plan.runtimeSearchPaths)
    hooks = {}
    for o in ctx.managed:
        if o == ctx.debug_output:
            continue
        lines = []
        for rel, var in sorted(table.items()):
            p = ctx.path_of(o, rel.strip("/"))
            if os.path.islink(p):
                continue                         # a stub forwards to the real owner
            if os.path.isdir(p):
                lines.append('addToSearchPath %s "%s"' % (var, p))
            elif os.path.isfile(p):
                lines.append('export %s="${%s:-%s}"' % (var, var, p))
        if lines:
            hook = os.path.join(ctx.out[o], "nix-support", "setup-hook")
            os.makedirs(os.path.dirname(hook), exist_ok=True)
            with open(hook, "a") as f:
                f.write("# rocky-partition: search paths of %s\n" % o)
                f.write("".join(l + "\n" for l in lines))
            hooks[o] = lines
    ctx.report.section("setupHooks", hooks)


def write_hidden(ctx):
    for y, xs in sorted(ctx.hidden.items()):
        paths = sorted(ctx.out[x] for x in xs if x != y)
        if not paths:
            continue
        p = os.path.join(ctx.out[y], "nix-support", "hidden-references")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write("".join(x + "\n" for x in paths))
    ctx.report.section("hiddenReferences", {y: sorted(xs) for y, xs in sorted(ctx.hidden.items())})


def write_out_files(ctx, late_doc):
    d = os.path.join(ctx.out[ctx.prefix_output], "nix-support")
    os.makedirs(d, exist_ok=True)
    stubs = getattr(ctx, "stubs", {})
    if stubs:
        with open(os.path.join(d, "rocky-stubs"), "w") as f:
            f.write("".join("%s %s\n" % (a, ctx.path_of(x, a)) for a, x in sorted(stubs.items())))
    if late_doc:
        _dump(os.path.join(d, "rocky-late.json"), late_doc)

