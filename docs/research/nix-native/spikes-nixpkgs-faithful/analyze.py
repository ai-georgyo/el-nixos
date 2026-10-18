#!/usr/bin/env python3
"""Spike B2: cross-subpackage reference analysis of a relocated single-prefix build.

usage: analyze.py <out>   (out = the prefix; out/nix-support/rpm-files/<subpkg>.txt)

For each file installed under the prefix, find every occurrence of the prefix
path and the relative path it names; map files and referenced paths to the
RPM subpackage that owns them (%files partition); report the subpackage
reference graph, its strongly connected components, and which references
would need rewriting (by file kind) if every subpackage were its own output
and the compile-time prefix were the main subpackage's output.
"""
import os, re, sys, json, collections

out = sys.argv[1].rstrip('/')
P = os.path.realpath(out)
files_dir = os.path.join(P, 'nix-support/rpm-files')
MAIN = 'glibc'

def norm(path):
    if path.startswith(P + '/'):
        return path[len(P) + 1:]
    if path == P:
        return ''
    if path.startswith('/usr/'):
        return path[5:]
    return path.lstrip('/')          # /etc/x -> etc/x, /var/x -> var/x

owner = {}          # rel path -> subpkg (files, symlinks and %dir)
isdir = {}
for fn in sorted(os.listdir(files_dir)):
    if not fn.endswith('.txt'):
        continue
    sub = fn[:-4]
    for line in open(os.path.join(files_dir, fn)):
        line = line.rstrip('\n')
        if not line:
            continue
        flags, perms, linkto, path = line.split('\t', 3)
        rel = norm(path)
        if rel in owner and owner[rel] != sub and not perms.startswith('d'):
            print(f'warning: {rel} in {owner[rel]} and {sub}')
        if perms.startswith('d'):
            isdir.setdefault(rel, set()).add(sub)
            owner.setdefault(rel, sub)
        else:
            owner[rel] = sub

# directory -> set of subpackages that have files below it
below = collections.defaultdict(set)
for rel, sub in owner.items():
    if rel in isdir:
        continue
    parts = rel.split('/')
    for i in range(1, len(parts)):
        below['/'.join(parts[:i])].add(sub)

def classify_target(rel):
    """owner of a referenced path: exact file, else directory (single/union)"""
    r = rel.rstrip('/')
    while r:
        if r in owner and r not in isdir:
            return ('file', owner[r], r)
        if r in below:
            subs = below[r]
            if len(subs) == 1:
                return ('dir', next(iter(subs)), r)
            return ('union', tuple(sorted(subs)), r)
        if r in isdir:
            return ('dir', tuple(sorted(isdir[r]))[0], r)
        r = r.rsplit('/', 1)[0] if '/' in r else ''
    return ('missing', None, rel)

def kind(path):
    with open(path, 'rb') as f:
        head = f.read(4)
    if head == b'\x7fELF':
        return 'elf'
    if path.endswith('.a'):
        return 'archive'
    with open(path, 'rb') as f:
        data = f.read(65536)
    if b'\0' in data:
        return 'binary'
    return 'text'

pat = re.compile(re.escape(P.encode()) + rb'(/[A-Za-z0-9._+\-/%$@{}]*)?')
edges = collections.defaultdict(lambda: collections.defaultdict(list))   # A -> B -> [(file, ref, kind)]
union_refs = collections.defaultdict(set)
missing = collections.defaultdict(set)
self_refs = collections.Counter()
nfiles = 0
for root, dirs, fs in os.walk(P):
    if root.startswith(os.path.join(P, 'nix-support')) or '/lib/debug' in root[len(P):] or root[len(P):].startswith('/src/debug'):
        dirs[:] = []
        continue
    for name in fs + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
        full = os.path.join(root, name)
        rel = full[len(P) + 1:]
        sub = owner.get(rel)
        if sub is None:
            continue
        nfiles += 1
        if os.path.islink(full):
            tgt = os.readlink(full)
            if tgt.startswith('/'):
                k, refs = 'symlink-abs', [tgt]
            else:
                k, refs = 'symlink-rel', [os.path.normpath(os.path.join(os.path.dirname(full), tgt))]
            hits = [norm(t) for t in refs if t.startswith(P)]
        else:
            k = kind(full)
            data = open(full, 'rb').read()
            hits = [m.group(1).decode('latin1') if m.group(1) else '' for m in pat.finditer(data)]
            hits = [h.lstrip('/') for h in hits]
        for h in set(hits):
            ck, tsub, trel = classify_target(h)
            if ck == 'missing':
                missing[sub].add((rel, h, k))
            elif ck == 'union':
                union_refs[trel].add((sub, rel, k))
            elif tsub == sub:
                self_refs[sub] += 1
            else:
                edges[sub][tsub].append((rel, h, k))

# SCCs (Tarjan)
nodes = sorted(set(owner.values()))
index, low, stack, on, sccs, counter = {}, {}, [], set(), [], [0]
def strong(v):
    index[v] = low[v] = counter[0]; counter[0] += 1; stack.append(v); on.add(v)
    for w in edges.get(v, {}):
        if w not in index:
            strong(w); low[v] = min(low[v], low[w])
        elif w in on:
            low[v] = min(low[v], index[w])
    if low[v] == index[v]:
        comp = []
        while True:
            w = stack.pop(); on.discard(w); comp.append(w)
            if w == v:
                break
        sccs.append(sorted(comp))
sys.setrecursionlimit(10000)
for v in nodes:
    if v not in index:
        strong(v)

def short(s):
    return s
print(f'prefix: {P}\nsubpackages: {len(nodes)}  files scanned: {nfiles}')
print('\n== cross-subpackage references (A -> B: count by file kind; examples)')
for a in sorted(edges):
    for b in sorted(edges[a]):
        lst = edges[a][b]
        kinds = collections.Counter(k for _, _, k in lst)
        ex = sorted(set((f, h) for f, h, _ in lst))[:3]
        print(f'{a} -> {b}: {dict(kinds)}')
        for f, h in ex:
            print(f'      {f}  ->  {h}')
print('\n== references to union directories (dir: referencing subpackages / kinds)')
for d in sorted(union_refs):
    s = union_refs[d]
    subs = collections.Counter(x[0] for x in s)
    kinds = collections.Counter(x[2] for x in s)
    nprov = len(below[d])
    print(f'{d}  [{nprov} providers]  referenced by {dict(subs)}  kinds {dict(kinds)}')
    for x in sorted(s)[:3]:
        print(f'      {x[1]}')
print('\n== references to paths that no subpackage ships (dangling)')
for s in sorted(missing):
    for x in sorted(missing[s])[:12]:
        print(f'{s}: {x[0]} -> {x[1]} ({x[2]})')
print('\n== SCCs with more than one subpackage (reference cycles)')
for c in sccs:
    if len(c) > 1:
        print('  ', c)
# references that need rewriting if the compile-time prefix is MAIN's output
print(f'\n== refs into non-{MAIN} subpackages, by referencing file kind (would need rewriting with prefix={MAIN} output)')
need = collections.Counter()
for a in edges:
    for b, lst in edges[a].items():
        if b != MAIN:
            for _, _, k in lst:
                need[k] += 1
print(dict(need))
