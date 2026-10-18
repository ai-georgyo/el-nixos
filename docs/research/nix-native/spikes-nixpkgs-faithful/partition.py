#!/usr/bin/env python3
"""Spike S5 prototype of tools/rocky-partition.py.

partition.py TREE PREFIX FILES_DIR MAP_JSON REPORT

TREE      the installed tree of the prefix (BUILDROOT/<prefix> after rpmbuild)
PREFIX    the compile-time prefix (= path of output "out")
FILES_DIR <subpkg>.txt lists: FILEFLAGS\tFILEMODES\tFILELINKTOS\tFILENAMES
MAP_JSON  {"subpkg": "outputName"}; output paths come from the environment
REPORT    report file

Moves (copies) every listed file into its output at the same relative path,
rewrites references to moved paths in text files and symlinks, reports
unrewritable binary references, and checks the output reference graph for
cycles (the check Nix would otherwise fail with).
"""
import os, sys, json, re, stat, shutil, collections

tree, P, files_dir, map_json, report_path = sys.argv[1:6]
smap = json.load(open(map_json))
outpath = {o: os.environ[o] for o in set(smap.values())}
rep = open(report_path, 'w')
def say(*a):
    print(*a, file=rep)

def norm(path):
    if path.startswith(P + '/'): return path[len(P) + 1:]
    if path == P: return ''
    if path.startswith('/usr/'): return path[5:]
    return path.lstrip('/')

entries = []        # (sub, rel, flags, perms, linkto)
owner = {}          # rel -> output
dirowners = collections.defaultdict(set)
for fn in sorted(os.listdir(files_dir)):
    if not fn.endswith('.txt'): continue
    sub = fn[:-4]
    if sub not in smap:
        continue                                   # debuginfo etc. not in this spike
    o = smap[sub]
    for line in open(os.path.join(files_dir, fn)):
        line = line.rstrip('\n')
        if not line: continue
        flags, perms, linkto, path = line.split('\t', 3)
        rel = norm(path)
        entries.append((sub, rel, flags, perms, linkto))
        if perms.startswith('d'):
            dirowners[rel].add(o)
        else:
            owner.setdefault(rel, o)
below = collections.defaultdict(set)
for rel, o in owner.items():
    parts = rel.split('/')
    for i in range(1, len(parts)):
        below['/'.join(parts[:i])].add(o)

def target_output(rel):
    r = rel.rstrip('/')
    while r:
        if r in owner: return owner[r], r
        if r in below:
            s = below[r]
            return (next(iter(s)) if len(s) == 1 else None), r
        r = r.rsplit('/', 1)[0] if '/' in r else ''
    return 'out', ''

# ---- 1. place files
for _o, _p in outpath.items():
    os.makedirs(_p, exist_ok=True)
inode_seen = {}
stats = collections.Counter()
for sub, rel, flags, perms, linkto in entries:
    o = smap[sub]
    dst = os.path.join(outpath[o], rel)
    src = os.path.join(tree, rel)
    if 'g' in flags:                               # %ghost: not shipped
        stats['ghost'] += 1; continue
    if perms.startswith('d'):
        os.makedirs(dst, exist_ok=True); continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.lexists(dst):
        stats['shared'] += 1; continue
    if not os.path.lexists(src):
        stats['not-in-spike-tree(/etc,/var)'] += 1; continue
    if perms.startswith('l'):
        t = os.readlink(src)
        if t.startswith('/') or True:
            # resolve the target; if it lives in another output, point there absolutely
            # resolve in the FHS namespace rpm saw: the link lives at its RPM path (path)
            fhs_link = '/usr/' + rel if not rel.startswith(('etc/', 'var/', 'run/')) else '/' + rel
            abs_t = t if t.startswith('/') else os.path.normpath(os.path.join(os.path.dirname(fhs_link), t))
            trel = norm(abs_t)
            to, _ = target_output(trel)
            if to is not None and to != o:
                t = os.path.join(outpath[to], trel); stats['symlink-retargeted'] += 1
            elif abs_t.startswith(('/nix/store/', '/usr/')) or t.startswith('/'):
                # same output: make it relative within the output
                t = os.path.relpath(trel, os.path.dirname(rel) or '.'); stats['symlink-relativized'] += 1
        os.symlink(t, dst); continue
    st = os.lstat(src)
    key = (st.st_dev, st.st_ino)
    if st.st_nlink > 1 and key in inode_seen and inode_seen[key][0] == o:
        os.link(inode_seen[key][1], dst); stats['hardlink'] += 1
    else:
        shutil.copy2(src, dst, follow_symlinks=False)
        os.chmod(dst, st.st_mode | stat.S_IWUSR)
        inode_seen.setdefault(key, (o, dst))
    stats['file'] += 1
say('placed:', dict(stats))

# ---- 2. rewrite / check references to $P/<rel> whose rel moved to another output
pat = re.compile(re.escape(P.encode()) + rb'(/[A-Za-z0-9._+\-/]*)?')
def is_elf(b): return b[:4] == b'\x7fELF'
rewrites = collections.Counter(); elf_bad = collections.defaultdict(set); union = collections.defaultdict(set)
for o, base in outpath.items():
    for root, dirs, fs in os.walk(base):
        for name in fs:
            f = os.path.join(root, name)
            if os.path.islink(f): continue
            data = open(f, 'rb').read()
            if P.encode() not in data: continue
            binary = is_elf(data) or b'\0' in data[:65536]
            def repl(m):
                rel = (m.group(1) or b'').decode('latin1').lstrip('/')
                to, r = target_output(rel)
                if to is None:
                    union[r].add((o, os.path.relpath(f, base)))
                    return m.group(0)
                if to == 'out':
                    return m.group(0)
                if binary:
                    elf_bad[(o, to)].add((os.path.relpath(f, base), rel))
                    return m.group(0)
                rewrites[(o, to)] += 1
                return outpath[to].encode() + m.group(0)[len(P):]
            new = pat.sub(repl, data)
            if new != data:
                os.chmod(f, os.stat(f).st_mode | stat.S_IWUSR)
                open(f, 'wb').write(new)
say('text rewrites (from-output -> to-output: count):', dict(rewrites))
say('binary references into other outputs (NOT rewritable):')
for k, v in sorted(elf_bad.items()):
    say('  ', k, len(v), sorted(v)[:6])
say('references to union directories (left to search paths):')
for r, v in sorted(union.items()):
    say('  ', r, sorted(set(x[0] for x in v)), sorted(v)[:3])

# ---- 3. reference graph between outputs (what Nix will scan) + SCCs
hashes = {o: os.path.basename(p)[:32].encode() for o, p in outpath.items()}
edges = collections.defaultdict(set)
for o, base in outpath.items():
    blob_hits = set()
    for root, dirs, fs in os.walk(base):
        for name in fs + dirs:
            f = os.path.join(root, name)
            data = os.readlink(f).encode() if os.path.islink(f) else (open(f, 'rb').read() if os.path.isfile(f) else b'')
            for o2, h in hashes.items():
                if o2 != o and o2 not in blob_hits and h in data:
                    blob_hits.add(o2); edges[o].add((o2, os.path.relpath(f, base)))
say('output reference graph:')
for o in sorted(edges):
    say('  ', o, '->', sorted(edges[o]))
idx, low, st, on, sccs, c = {}, {}, [], set(), [], [0]
sys.setrecursionlimit(10000)
def sc(v):
    idx[v] = low[v] = c[0]; c[0] += 1; st.append(v); on.add(v)
    for w, _ in edges.get(v, ()):
        if w not in idx: sc(w); low[v] = min(low[v], low[w])
        elif w in on: low[v] = min(low[v], idx[w])
    if low[v] == idx[v]:
        comp = []
        while True:
            w = st.pop(); on.discard(w); comp.append(w)
            if w == v: break
        sccs.append(comp)
for v in outpath:
    if v not in idx: sc(v)
cyc = [s for s in sccs if len(s) > 1]
say('cycles:', cyc if cyc else 'none')
rep.close()
print(open(report_path).read())
sys.exit(1 if cyc else 0)
