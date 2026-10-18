"""--replay <tree> --remap OLD=NEW (design §11.4, development only).

The partition runs against the kept build tree ($tree/BUILDROOT, $tree/RPMS,
$tree/prefix) with OLD (the tree's compile prefix) as the prefix; at the end
every output is remapped OLD -> NEW (same length): raw bytes, store-by-pieces
windows of OLD, symlink targets, and whole-file compressed members
(re-encoded). Never used for shipped outputs: the bytes are a development
copy ([NF-S5] did the same)."""
import os

from . import decoders as D
from . import scan as S
from .refs import walk_files


def tree_args(tree):
    with open(os.path.join(tree, "prefix")) as f:
        prefix = f.read().strip()
    return {"buildroot": os.path.join(tree, "BUILDROOT"), "rpmsDir": os.path.join(tree, "RPMS"), "prefix": prefix}


def remap_bytes(data, old, new, hash_start):
    if old not in data and not _any_window(data, old, hash_start):
        return data
    data = data.replace(old, new)
    for k, w in S.windows(old, hash_start):
        if w in data:
            data = data.replace(w, new[k:k + S.WINDOW])
    return data


def _any_window(data, old, hash_start):
    return any(w in data for _k, w in S.windows(old, hash_start))


def remap_outputs(ctx):
    old, new = ctx.replay_old.encode(), ctx.out[ctx.prefix_output].encode()
    assert len(old) == len(new)
    hs = len(os.path.dirname(ctx.replay_old)) + 1
    rep = ctx.report
    n = 0
    for o in ctx.managed:
        root = ctx.out[o]
        for d, dirs, files in os.walk(root):
            for x in files + dirs:
                p = os.path.join(d, x)
                if os.path.islink(p):
                    t = os.readlink(p)
                    if ctx.replay_old in t:
                        os.unlink(p)
                        os.symlink(t.replace(ctx.replay_old, ctx.out[ctx.prefix_output]), p)
                        n += 1
        for rel, p in walk_files(root):
            with open(p, "rb") as f:
                data = f.read()
            nd = data
            kind = D.compression_of(data[:16])
            if kind:
                inner = D.decompress(kind, data)
                if inner is not None and (old in inner or _any_window(inner, old, hs)):
                    enc = D.recompress(kind, remap_bytes(inner, old, new, hs))
                    if enc is not None:
                        nd = enc
            nd = remap_bytes(nd, old, new, hs)
            if nd != data:
                os.chmod(p, os.stat(p).st_mode | 0o200)
                with open(p, "wb") as f:
                    f.write(nd)
                n += 1
    # what survived (nested sections, ...)
    left = []
    oh = old[hs:hs + 32]
    for o in ctx.managed:
        for rel, p in walk_files(ctx.out[o]):
            with open(p, "rb") as f:
                data = f.read()
            if oh in data:
                left.append("%s/%s" % (o, rel))
            else:
                for _w, blob in D.nested_blobs(data):
                    if oh in blob:
                        left.append("%s/%s (nested)" % (o, rel))
                        break
    for x in left[:ctx.plan.maxSamples]:
        rep.warning("replay-remap-incomplete", "%s still contains the replayed tree's prefix hash" % x, file=x)
    if len(left) > ctx.plan.maxSamples:
        rep.warning("replay-remap-incomplete", "... %d files in all" % len(left))
    rep.section("replay", {"remappedFiles": n, "leftovers": left[:200]})
