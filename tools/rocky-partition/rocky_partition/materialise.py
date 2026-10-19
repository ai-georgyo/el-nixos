"""Phase B (materialise) and Phase C (symlinks), design §2.3-2.4."""
import collections
import os
import posixpath
import shutil
import stat

from .plan import rel_match

RUNTIME_ROOTS = ("proc", "dev", "sys", "tmp")


def locate(br, hpath):
    """BUILDROOT path of a header path (through the BUILDROOT/usr -> prefix
    fold link; usrmerge spellings also looked up below usr/)"""
    p = os.path.join(br, hpath.lstrip("/"))
    if os.path.lexists(p):
        return p
    top = hpath.lstrip("/").split("/", 1)[0]
    if top in ("bin", "sbin", "lib", "lib64"):
        q = os.path.join(br, "usr", hpath.lstrip("/"))
        if os.path.lexists(q):
            return q
    return None


class _DirCache:
    def __init__(self):
        self.c = {}

    def phys(self, p):
        d, b = os.path.split(p)
        r = self.c.get(d)
        if r is None:
            r = self.c[d] = os.path.realpath(d)
        return os.path.join(r, b)


def unclaimed(ctx, br):
    """files/symlinks in BUILDROOT that no header entry claims"""
    dc = _DirCache()
    claimed = set()
    for e in ctx.entries:
        if e.kind == "dir":
            continue
        p = locate(br, e.hpath)
        if p is not None:
            claimed.add(dc.phys(p))
    brr = os.path.realpath(br)
    fold = os.path.join(brr, "usr")
    out = []
    for root, dirs, files in os.walk(brr):
        dirs.sort()
        for n in sorted(files + [d for d in dirs if os.path.islink(os.path.join(root, d))]):
            p = os.path.join(root, n)
            if p == fold and os.path.islink(p):
                continue
            if p not in claimed:
                out.append(os.path.relpath(p, brr))
    return out


def materialise(ctx, br, copy):
    rep = ctx.report
    for rel in unclaimed(ctx, br):
        rep.error("unclaimed-file", "BUILDROOT/%s is claimed by no RPM" % rel, path=rel)
    for o in ctx.out:
        os.makedirs(ctx.out[o], exist_ok=True)
    # destinations per source (move only when a source has one destination)
    dests = collections.Counter()
    for e in ctx.entries:
        if e.kind == "file" and not e.ghost and e.ns not in ("dropped",):
            dests[e.hpath] += 1
    placed = {}                 # (output, rel) -> Entry
    inodes = {}                 # (output, dev, ino) -> dst
    split_groups = set()
    links = []
    stats = collections.Counter()
    shared = collections.defaultdict(set)
    for e in sorted(ctx.entries, key=lambda e: (ctx.order[e.output], e.rel, e.sub)):
        if e.ns == "dropped" or e.ghost or e.rel == "":
            stats["ghost" if e.ghost else "skipped"] += 1
            continue
        key = (e.output, e.rel)
        dst = ctx.path_of(e.output, e.rel)
        if e.kind == "dir":
            if os.path.lexists(dst) and not os.path.isdir(dst):
                continue
            os.makedirs(dst, exist_ok=True)
            continue
        if key in placed:
            stats["same-output-duplicate"] += 1
            continue
        src = locate(br, e.hpath)
        if src is None:
            rep.error("missing-file", "%s: %s is not in BUILDROOT" % (e.sub, e.hpath), subpackage=e.sub, path=e.hpath)
            continue
        placed[key] = e
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.islink(src):
            links.append((e, src, dst))
            continue
        st = os.lstat(src)
        if not stat.S_ISREG(st.st_mode):
            rep.error("missing-file", "%s: %s is not a regular file in BUILDROOT" % (e.sub, e.hpath), subpackage=e.sub)
            continue
        if dests[e.hpath] > 1:
            shared[e.hpath].add(e.output)
        ik = (e.output, st.st_dev, st.st_ino)
        if st.st_nlink > 1 and ik in inodes:
            os.link(inodes[ik], dst)
            stats["hardlink"] += 1
            continue
        if st.st_nlink > 1:
            for (o2, dev, ino), _d in inodes.items():
                if (dev, ino) == (st.st_dev, st.st_ino) and o2 != e.output:
                    split_groups.add((st.st_dev, st.st_ino))
                    break
        if not copy and dests[e.hpath] == 1 and st.st_nlink == 1:
            try:
                os.rename(src, dst)
            except OSError:
                shutil.copy2(src, dst)
        else:
            shutil.copy2(src, dst)
        mode = st.st_mode
        if mode & (stat.S_ISUID | stat.S_ISGID):
            rep.info("setid-dropped", "%s/%s: mode %o" % (e.output, e.rel, stat.S_IMODE(mode)), output=e.output, file=e.rel)
        os.chmod(dst, (stat.S_IMODE(mode) & 0o1777) | stat.S_IWUSR | stat.S_IRUSR)
        inodes[ik] = dst
        stats["file"] += 1
    for h, os_ in sorted(shared.items()):
        rep.info("shared-file", "%s is owned by %s (copied into each)" % (h, ", ".join(sorted(os_))), path=h)
    if split_groups:
        rep.info("hardlink-split", "%d hard link groups span outputs (split into copies)" % len(split_groups))
    ctx.placed = placed
    rep.section("materialise")["stats"] = dict(stats)
    symlinks(ctx, links)
    pull(ctx)


def pull(ctx):
    """pullToPrefix: regular files of a non-prefix output X at a rel the
    prefix output's compiled-in defaults name, where no forwarding stub can
    serve (X references the prefix output, so a stub $P/rel -> $X/rel would
    close a cycle): the file moves into the prefix output and X/rel becomes
    a symlink to it (X -> prefix: the edge X already has).  glibc:
    share/locale/locale.alias (libc's LOCALE_ALIAS_PATH, glibc-common) and
    lib/locale/C.utf8 (complocaledir, glibc-common).  Runs after the symlink
    phase: links into rel already point at X/rel and keep resolving.  The
    ownership index then names the prefix output for rel."""
    pats = ctx.plan.pullToPrefix
    if not pats:
        return
    rep, po = ctx.report, ctx.prefix_output
    used, moved = set(), []
    for (o, rel), e in sorted(ctx.placed.items(), key=lambda kv: (ctx.order[kv[0][0]], kv[0][1])):
        if o in (po, ctx.debug_output):
            continue
        pat = rel_match(rel, list(pats))
        if pat is None:
            continue
        used.add(pat)
        src, dst = ctx.path_of(o, rel), ctx.path_of(po, rel)
        if e.kind != "file" or os.path.islink(src) or not os.path.isfile(src):
            rep.error("pull-to-prefix", "%s/%s: pullToPrefix %s moves regular files only" % (o, rel, pat),
                      output=o, file=rel)
            continue
        if os.path.lexists(dst):
            rep.error("pull-to-prefix", "%s/%s: pullToPrefix %s: %s/%s exists" % (o, rel, pat, po, rel),
                      output=o, file=rel)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.rename(src, dst)
        os.symlink(dst, src)
        ents = ctx.owners[rel].pop(o, [e])
        ctx.owners[rel].setdefault(po, []).extend(ents)
        parts = rel.split("/")
        for i in range(1, len(parts)):
            ctx.implied["/".join(parts[:i])].add(po)
        ctx.add_edge(o, po, "pullToPrefix %s" % rel)
        moved.append([o, rel])
        rep.info("pull-to-prefix", "%s/%s moved to %s, %s/%s -> it (%s)" % (o, rel, po, o, rel, pats[pat]),
                 output=o, file=rel)
    for pat in sorted(set(pats) - used):
        rep.error("pull-to-prefix", "pullToPrefix %s matches no regular file of a non-prefix output" % pat)
    rep.section("pullToPrefix", {"moved": moved})


def _fhs_dir(e):
    """directory of a header entry in the rpm (FHS) namespace"""
    if e.ns in ("usr", "debug"):
        return posixpath.dirname("/usr/" + e.rel)
    return posixpath.dirname("/" + e.rel)


def symlinks(ctx, links):
    rep = ctx.report
    stats = collections.Counter()
    samples = rep.section("symlinks", {"retargeted": [], "dangling": []})
    for e, src, dst in links:
        t = os.readlink(src)
        abs_t = t if t.startswith("/") else posixpath.normpath(posixpath.join(_fhs_dir(e), t))
        tns, trel = ctx.canon_target(abs_t)
        for _ in range(8):
            # debug build-id links to a dropped usr/lib/.build-id link: follow it
            # to the binary (gdb's build-id lookup then finds it in its output)
            d = ctx.dropped.get(trel) if tns == "usr" else None
            if d is None or d.kind != "link" or not d.linkto:
                break
            lt = d.linkto
            abs_t = lt if lt.startswith("/") else posixpath.normpath(posixpath.join(_fhs_dir(d), lt))
            tns, trel = ctx.canon_target(abs_t)
        new = None
        if tns == "fhs" or (tns == "other" and trel.split("/", 1)[0] in RUNTIME_ROOTS):
            new = "/" + trel                       # runtime FHS target: stays FHS
            stats["fhs"] += 1
        elif tns == "other":
            new = t
            rep.warning("symlink-dangling", "%s/%s -> %s: target outside the package namespaces" % (e.output, e.rel, t),
                        output=e.output, file=e.rel)
        else:
            owners, kind = ctx.lookup(trel)
            if trel == "":
                owners = {ctx.prefix_output}
            if e.output in owners:
                new = posixpath.relpath(trel or ".", posixpath.dirname(e.rel) or ".")
                stats["relative"] += 1
                if trel in ctx.owners:
                    for s in ctx.subs_of(e.output, trel):
                        if s != e.sub:
                            ctx.subref[(e.sub, s)] += 1
            elif len(owners) == 1:
                x = next(iter(owners))
                new = ctx.path_of(x, trel)
                ctx.add_edge(e.output, x, "symlink %s" % e.rel)
                stats["cross-output"] += 1
                if len(samples["retargeted"]) < ctx.plan.maxSamples:
                    samples["retargeted"].append([e.output, e.rel, x + ":" + trel])
            elif owners:
                req = sorted(o for o in owners if ctx.requires(e.output, o))
                x = req[0] if len(req) == 1 else sorted(owners, key=ctx.order.get)[0]
                if len(req) != 1:
                    rep.error("symlink-union", "%s/%s -> %s: target owned by %s" % (e.output, e.rel, t, ", ".join(sorted(owners))),
                              output=e.output, file=e.rel, owners=sorted(owners))
                new = ctx.path_of(x, trel)
                ctx.add_edge(e.output, x, "symlink %s" % e.rel)
            else:
                ok = rel_match(trel, ctx.plan.danglingOk) or rel_match(e.rel, ctx.plan.danglingOk)
                new = t                            # left as it was (dangles either way)
                (rep.info if ok else rep.error)(
                    "symlink-dangling", "%s/%s -> %s: target in no output%s" % (e.output, e.rel, t, " (danglingOk)" if ok else ""),
                    output=e.output, file=e.rel, target=t)
                stats["dangling"] += 1
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(new, dst)
    rep.section("symlinks")["stats"] = dict(stats)
