"""Phase I: per-output metadata and setup hooks (design §2.10).

  <o>/nix-support/rpm/<subpkg>.json   files (flags, modes, owners, caps,
                                      digests), deps, scriptlets, triggers
  <o>/nix-support/rpm-name            the subpackage name(s) of <o>
  <o>/nix-support/setup-hook          search-path exports (if any)
  <o>/nix-support/hidden-references   store paths Nix's scanner cannot see
  $out/nix-support/rocky-stubs        forwarding stubs ("rel target")
  $out/nix-support/rocky-late.json    L* (if lateBind)"""
import collections
import glob
import json
import os
import stat

from . import headers as H
from . import scan as S


def _usr(obj, prefix, key=None):
    """the compile prefix -> /usr (the rpm namespace) in every string except
    "rel" (the path inside the output: a debug file's rel mirrors the prefix,
    lib/debug/<P>/..., and must stay exact)"""
    if isinstance(obj, str):
        return obj if key == "rel" else obj.replace(prefix, "/usr")
    if isinstance(obj, list):
        return [_usr(x, prefix, key) for x in obj]
    if isinstance(obj, dict):
        return {k: _usr(v, prefix, k) for k, v in obj.items()}
    return obj


def _dump(path, doc, prefix=None):
    """JSON; the compile prefix is written as /usr, so metadata references
    no output (Nix would see an edge) except through a debug file's rel"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = json.dumps(_usr(doc, prefix) if prefix else doc, indent=1, sort_keys=True) + "\n"
    with open(path, "w") as f:
        f.write(text)
    return text


def _check_store_paths(ctx, o, name, text):
    """store paths in header data (scriptlets, triggers, dependencies) are
    references of the output too: the foreign-store-path rule of phase D"""
    own = {ctx.hash_of(p) for p in ctx.out.values()} | {ctx.hash_of(ctx.P)}
    found = []
    for m in S.store_re(sorted({ctx.store_dir, "/nix/store"})).finditer(text.encode()):
        h = m.group(1).decode()
        if h in own:
            continue
        found.append(h)
        if ctx.allowed is not None and h not in ctx.allowed:
            ctx.report.error("foreign-store-path", "%s/nix-support/rpm/%s (rpm header data) references %s, not an"
                             " allowed store path" % (o, name, m.group(0).decode()), output=o, file="nix-support/rpm/" + name)
    return found


def write_metadata(ctx):
    by_sub = collections.defaultdict(list)
    for e in ctx.entries:
        by_sub[e.sub].append(e)
    names = collections.defaultdict(set)
    foreign = collections.defaultdict(list)
    # replay: a debug rel names the tree's prefix, renamed by the remap
    old_rel, new_rel = ctx.P.lstrip("/"), ctx.out[ctx.prefix_output].lstrip("/")
    if old_rel == new_rel:
        old_rel = None
    for s, o in ctx.sub_output.items():
        names[o].add(s)
        rec = ctx.subs[s]
        files = []
        for e in by_sub[s]:
            files.append({
                "path": e.hpath, "rel": e.rel.replace(old_rel, new_rel) if old_rel else e.rel, "namespace": e.ns,
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
        text = _dump(os.path.join(ctx.out[o], "nix-support", "rpm", s + ".json"), doc, ctx.P)
        for h in _check_store_paths(ctx, o, s + ".json", text):
            foreign[h[:8] + "..."].append("%s:nix-support/rpm/%s.json" % (o, s))
    if foreign:
        ctx.report.section("metadataStorePaths", {h: sorted(set(v))[:10] for h, v in sorted(foreign.items())})
    for o in ctx.managed:
        d = os.path.join(ctx.out[o], "nix-support")
        os.makedirs(d, exist_ok=True)
        if names.get(o):
            with open(os.path.join(d, "rpm-name"), "w") as f:
                f.write("".join(n + "\n" for n in sorted(names[o])))


def _provides(p, provider):
    """does directory p provide its variable (a provider glob needs a match
    that exists, symlinks followed: lib/locale/*/LC_CTYPE)"""
    if not provider:
        return True
    return any(os.path.exists(x) for x in glob.glob(os.path.join(glob.escape(p), provider)))


def write_hooks(ctx):
    """setup hooks for search paths (runtimeSearchPaths and searchPaths of the
    plan), by the contract of lib/rocky/unions.nix (plan.searchPathRules,
    keyed by variable; a variable without a rule is a plain list):
      hook false     no line (a run-time-only variable: profiles set it)
      provider glob  a directory is an entry only if <dir>/<glob> matches
                     (LOCPATH: */LC_CTYPE; a lib/locale holding only the
                     locale-archive is not a LOCPATH entry)
      list           [ -n "${Y-}" ] || ... per Y in yieldsTo, then
                     addToSearchPath VAR "<dir>"
      single / file  export VAR="${VAR:-<path>}", then `unset V` for every V
                     whose yieldsTo names VAR
    so whichever order the hooks are sourced in, a provided LOCALE_ARCHIVE
    leaves LOCPATH unset (glibc ignores the archive whenever LOCPATH is set)"""
    rules = ctx.plan.searchPathRules
    table = dict(ctx.plan.searchPaths)
    table.update(ctx.plan.runtimeSearchPaths)
    yielders = {}
    for v, r in sorted(rules.items()):
        for y in r.get("yieldsTo") or []:
            yielders.setdefault(y, []).append(v)
    hooks, skipped = {}, {}
    for o in ctx.managed:
        if o == ctx.debug_output:
            continue
        lines = []
        for rel, var in sorted(table.items()):
            r = rules.get(var, {})
            p = ctx.path_of(o, rel.strip("/"))
            if os.path.islink(p):
                continue                         # a stub forwards to the real owner
            if not (os.path.isdir(p) or os.path.isfile(p)):
                continue
            if r.get("hook") is False:
                skipped.setdefault(o, []).append("%s %s (run time only)" % (var, rel))
                continue
            if os.path.isdir(p) and r.get("kind", "list") == "list":
                if not _provides(p, r.get("provider")):
                    skipped.setdefault(o, []).append("%s %s (no %s)" % (var, rel, r.get("provider")))
                    continue
                guard = "".join('[ -n "${%s-}" ] || ' % y for y in r.get("yieldsTo") or [])
                lines.append('%saddToSearchPath %s "%s"' % (guard, var, p))
            else:
                lines.append('export %s="${%s:-%s}"' % (var, var, p))
                lines.extend("unset %s" % v for v in yielders.get(var, []))
        if lines:
            hook = os.path.join(ctx.out[o], "nix-support", "setup-hook")
            os.makedirs(os.path.dirname(hook), exist_ok=True)
            with open(hook, "a") as f:
                f.write("# rocky-partition: search paths of %s\n" % o)
                f.write("".join(l + "\n" for l in lines))
            hooks[o] = lines
    ctx.report.section("setupHooks", hooks)
    if skipped:
        ctx.report.section("setupHooksSkipped", skipped)


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

