#!/usr/bin/env python3
"""Resolve an SRPM's BuildRequires to a mock-like buildroot package closure.

Usage (from the repository root):

    nix run .#resolve-buildrequires -- glibc [--format md|json|text] [--recursive]
    python3 -I tools/resolve-buildrequires.py glibc --format md

Inputs: lock/rocky-<rel>/{srpms.json,rpms.json,deps.json.gz} written by
tools/update-lock.py (the rpmvercmp/EVR code is shared with it).

What it emulates (mock + dnf/libsolv, approximately):

1. Transaction 1 = mock's ``chroot_setup_cmd`` for rocky-10 (from
   mock-core-configs templates/rocky-10.tpl, Rocky 10's comps has no
   buildsys-build group):  install bash bzip2 coreutils cpio diffutils
   findutils gawk glibc-minimal-langpack grep gzip info patch redhat-rpm-config
   rocky-release rpm-build sed tar unzip util-linux which xz
   (AlmaLinux 10 is identical with redhat-release instead of rocky-release;
   CentOS Stream 10 uses centos-stream-release and adds shadow-utils.)
2. Transaction 2 = ``dnf builddep`` of the SRPM header's BuildRequires.
   Both with ``install_weak_deps=0`` (mock's dnf.conf), so only Requires.

Resolution rules (tuned until they matched dnf5/libsolv exactly on 110 of 110
sampled SRPMs, then 150/150 on a held-out sample; see
docs/research/glibc-buildroot-closure.md):

- Top-level jobs (install args, BuildRequires): a package whose *name*
  matches (and whose EVR satisfies the version) wins, as in ``dnf install``.
- A requirement already satisfied by the selection is not re-resolved.
- Requirements with exactly one provider are applied first; requirements that
  need a choice are deferred until nothing else is left, then decided one at a
  time in FIFO order (libsolv: unit propagation before decisions).
- A choice prefers, in order: an alternative that a selected package
  Recommends/Suggests or that Supplements/Enhances a selected package (libsolv
  uses weak deps for this even with install_weak_deps=0, e.g. openssl-libs
  Suggests openssl-fips-provider); the alternative with the most Requires
  already satisfied by the selection (php8.4-process over php-process once
  php8.4-common is in; libcurl over libcurl-minimal); a name equal to the dep
  name; the shortest name; alphabetical.  Every non-obvious pick is reported.
- Rich deps: ``and``/``or``/``with``/``without``/``if``/``unless``/``else``;
  ``if``/``unless`` are re-evaluated to a fixpoint against the selection.
Versioned deps use rpm's range-overlap semantics; an unversioned provide
satisfies any version.  File deps are matched against the file subset in
primary.xml and against explicit file provides, with a UsrMove fallback
(/bin -> /usr/bin, /sbin -> /usr/sbin, /lib64 -> /usr/lib64, /lib -> /usr/lib).
Files only listed in filelists.xml are reported as unresolved.

Not emulated: arch-conditional BuildRequires (the SRPM header was produced on
one build host), %generate_buildrequires (dynamic BRs), Conflicts/Obsoletes
(reported only), repo priorities, modularity (none in EL10).
"""

import argparse
import collections
import gzip
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True  # do not leave tools/__pycache__ behind
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("update_lock", os.path.join(_here, "update-lock.py"))
UL = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(UL)

MOCK_CHROOT_SETUP = {
    "rocky-10": "bash bzip2 coreutils cpio diffutils findutils gawk glibc-minimal-langpack grep gzip info patch redhat-rpm-config rocky-release rpm-build sed tar unzip util-linux which xz",
    "almalinux-10": "bash bzip2 coreutils cpio diffutils redhat-release findutils gawk glibc-minimal-langpack grep gzip info patch redhat-rpm-config rpm-build sed tar unzip util-linux which xz",
    "centos-stream-10": "bash bzip2 centos-stream-release coreutils cpio diffutils findutils gawk glibc-minimal-langpack grep gzip info patch redhat-rpm-config rpm-build sed shadow-utils tar unzip util-linux which xz",
}

OPS = {"=": ("EQ",), "==": ("EQ",), "<": ("LT",), ">": ("GT",),
       "<=": ("LT", "EQ"), "=<": ("LT", "EQ"), ">=": ("GT", "EQ"), "=>": ("GT", "EQ")}
USRMOVE = [("/bin/", "/usr/bin/"), ("/sbin/", "/usr/sbin/"),
           ("/lib64/", "/usr/lib64/"), ("/lib/", "/usr/lib/")]


# --------------------------------------------------------------------------
# dependency parsing
# --------------------------------------------------------------------------

class Simple:
    __slots__ = ("name", "op", "evr", "text")

    def __init__(self, name, op=None, evr=None):
        self.name, self.op = name, op
        self.evr = UL.parse_evr(evr) if evr is not None else None
        self.text = name if op is None else "%s %s %s" % (name, op, evr)

    def __repr__(self):
        return self.text


class Rich:
    __slots__ = ("op", "args", "text")

    def __init__(self, op, args, text):
        self.op, self.args, self.text = op, args, text

    def __repr__(self):
        return self.text


def _skip_ws(s, i):
    while i < len(s) and s[i].isspace():
        i += 1
    return i


def _read_word(s, i):
    """Read a token: up to whitespace or an unbalanced ')'."""
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c.isspace():
            break
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                break
            depth -= 1
        j += 1
    return s[i:j], j


def _parse_operand(s, i):
    i = _skip_ws(s, i)
    if s[i] == "(":
        return _parse_rich(s, i)
    name, i = _read_word(s, i)
    k = _skip_ws(s, i)
    op, k2 = _read_word(s, k)
    if op in OPS:
        evr, k3 = _read_word(s, _skip_ws(s, k2))
        return Simple(name, op, evr), k3
    return Simple(name), i


def _parse_rich(s, i):
    start = i
    assert s[i] == "("
    i += 1
    terms, ops = [], []
    while True:
        node, i = _parse_operand(s, i)
        terms.append(node)
        i = _skip_ws(s, i)
        if i >= len(s):
            raise ValueError("unterminated rich dep: %r" % s)
        if s[i] == ")":
            i += 1
            break
        op, i = _read_word(s, i)
        if op not in ("and", "or", "if", "unless", "else", "with", "without"):
            raise ValueError("bad rich op %r in %r" % (op, s))
        ops.append(op)
    text = s[start:i]
    if not ops:
        return terms[0], i
    if ops[0] in ("if", "unless"):
        # A if B [else C]
        if len(ops) == 1:
            return Rich(ops[0], [terms[0], terms[1], None], text), i
        if len(ops) == 2 and ops[1] == "else":
            return Rich(ops[0], [terms[0], terms[1], terms[2]], text), i
        raise ValueError("bad conditional %r" % s)
    if len(set(ops)) != 1:
        raise ValueError("mixed ops without parentheses %r" % s)
    return Rich(ops[0], terms, text), i


def parse_dep(s):
    s = s.strip()
    if s.startswith("("):
        node, i = _parse_rich(s, 0)
        if _skip_ws(s, i) != len(s):
            raise ValueError("trailing garbage in %r" % s)
        return node
    parts = s.split()
    if len(parts) == 1:
        return Simple(parts[0])
    if len(parts) == 3 and parts[1] in OPS:
        return Simple(parts[0], parts[1], parts[2])
    raise ValueError("cannot parse dep %r" % s)


def _leaves(node):
    if isinstance(node, Simple):
        return [node]
    out = []
    for a in node.args:
        if a is not None:
            out.extend(_leaves(a))
    return out


def _wanted_leaves(node):
    """Leaves that a requirement asks to be installed (not conditions)."""
    if isinstance(node, Simple):
        return [node]
    if node.op in ("if", "unless"):
        return _wanted_leaves(node.args[0]) + (
            _wanted_leaves(node.args[2]) if node.args[2] is not None else [])
    if node.op == "without":
        return _wanted_leaves(node.args[0])
    return [x for a in node.args for x in _wanted_leaves(a)]


def ranges_overlap(pop, pevr, rop, revr):
    """rpmdsCompare(): does provide (pop, pevr) satisfy require (rop, revr)?"""
    if pop is None or rop is None or pevr is None or revr is None:
        return True
    pf, rf = set(OPS[pop]), set(OPS[rop])
    sense = UL.evrcmp(pevr, revr)
    if sense < 0:
        return "GT" in pf or "LT" in rf
    if sense > 0:
        return "LT" in pf or "GT" in rf
    return bool(("EQ" in pf and "EQ" in rf) or ("LT" in pf and "LT" in rf)
                or ("GT" in pf and "GT" in rf))


# --------------------------------------------------------------------------
# package universe
# --------------------------------------------------------------------------

class Universe:
    def __init__(self, lockdir):
        with open(os.path.join(lockdir, "srpms.json")) as f:
            self.srpms = json.load(f)["srpms"]
        with open(os.path.join(lockdir, "rpms.json")) as f:
            self.rpms = json.load(f)["rpms"]
        with gzip.open(os.path.join(lockdir, "deps.json.gz")) as f:
            self.deps = json.load(f)["packages"]
        self.prov = collections.defaultdict(list)  # name -> [(key, op, evr)]
        self.by_name = collections.defaultdict(list)
        self._req_cache = {}
        for key, d in self.deps.items():
            self.by_name[self.rpms[key]["name"]].append(key)
            for p in d["provides"]:
                sd = parse_dep(p)
                self.prov[sd.name].append((key, sd.op, sd.evr))
            for fn in d["files"]:
                self.prov[fn].append((key, None, None))

    def requires(self, key):
        r = self._req_cache.get(key)
        if r is None:
            r = []
            for s in self.deps[key]["requires"]:
                try:
                    r.append(parse_dep(s))
                except ValueError as e:
                    print("warning: %s: %s" % (key, e), file=sys.stderr)
            self._req_cache[key] = r
        return r

    def providers(self, sd):
        """Packages providing Simple dep sd (sorted, deduplicated)."""
        cands = self.prov.get(sd.name, [])
        found = sorted({k for k, op, evr in cands if ranges_overlap(op, evr, sd.op, sd.evr)})
        how = None
        if not found and sd.name.startswith("/"):
            for old, new in USRMOVE:
                if sd.name.startswith(old):
                    alt = new + sd.name[len(old):]
                    found = sorted({k for k, _op, _e in self.prov.get(alt, [])})
                    if found:
                        how = "usrmove:" + alt
                    break
        return found, how


# --------------------------------------------------------------------------
# resolver
# --------------------------------------------------------------------------

class Resolver:
    def __init__(self, uni):
        self.u = uni
        self.selected = {}            # key -> reason (first requirer)
        self.order = []
        self.choices = []             # (dep, picked, alternatives, requirer)
        self.unresolved = []          # (dep, requirer)
        self.notes = []
        self.conditionals = []        # (Rich, requirer)
        self.queue = collections.deque()
        self.weak_wanted = set()
        self._failed = set()
        self.deferred = collections.deque()  # (node, requirer) needing a choice

    # -- helpers
    def fail(self, text, why):
        if (text, why) not in self._failed:
            self._failed.add((text, why))
            self.unresolved.append((text, why))

    def add(self, key, why):
        if key in self.selected:
            return
        self.selected[key] = why
        self.order.append(key)
        self.queue.append(key)
        d = self.u.deps[key]
        for w in d.get("recommends", []) + d.get("suggests", []):
            try:
                node = parse_dep(w)
            except ValueError:
                continue
            for leaf in _leaves(node):
                self.weak_wanted.update(self.u.providers(leaf)[0])

    def weakly_preferred(self, k):
        """libsolv prefers alternatives that a selected package Recommends or
        Suggests, or that Supplement/Enhance something selected -- even with
        install_weak_deps=0."""
        if k in self.weak_wanted:
            return True
        d = self.u.deps[k]
        for w in d.get("supplements", []) + d.get("enhances", []):
            try:
                if self.satisfied(parse_dep(w)):
                    return True
            except ValueError:
                continue
        return False

    def satisfied(self, node):
        if isinstance(node, Simple):
            found, _ = self.u.providers(node)
            return any(k in self.selected for k in found)
        op, a = node.op, node.args
        if op in ("with", "without"):
            # one and the same package must satisfy (or not) both sides
            s = self.provider_set(node)
            if s is not None:
                return any(k in self.selected for k in s)
            if op == "with":
                return all(self.satisfied(x) for x in a)
            return self.satisfied(a[0]) and not self.satisfied(a[1])
        if op == "and":
            return all(self.satisfied(x) for x in a)
        if op == "or":
            return any(self.satisfied(x) for x in a)
        if op == "if":
            if self.satisfied(a[1]):
                return self.satisfied(a[0])
            return a[2] is None or self.satisfied(a[2])
        if op == "unless":
            if not self.satisfied(a[1]):
                return self.satisfied(a[0])
            return a[2] is None or self.satisfied(a[2])
        raise AssertionError(op)

    def pick(self, dep_text, dep_name, cands, why):
        if len(cands) == 1:
            return cands[0]

        def met(k):
            # requirements of this candidate that the current selection
            # already satisfies: approximates libsolv's preference for
            # alternatives that share dependencies with what is already
            # chosen (php8.4-process over php-process once php8.4-common is
            # in; libcurl over libcurl-minimal).
            return sum(1 for r in self.u.requires(k)
                       if isinstance(r, Simple) and self.satisfied(r))

        def rank(k):
            n = self.u.rpms[k]["name"]
            return (not self.weakly_preferred(k), -met(k), n != dep_name, len(n), n, k)

        best = sorted(cands, key=rank)
        picked = best[0]
        if self.u.rpms[picked]["name"] != dep_name:
            self.choices.append((dep_text, picked, best[1:], why))
        return picked

    def provider_set(self, node):
        """For 'with'/'without' on simple operands: candidate keys or None."""
        if isinstance(node, Simple):
            return set(self.u.providers(node)[0])
        if node.op == "with":
            sets = [self.provider_set(x) for x in node.args]
            if any(s is None for s in sets):
                return None
            return set.intersection(*sets)
        if node.op == "without":
            a, b = (self.provider_set(x) for x in node.args)
            if a is None or b is None:
                return None
            return a - b
        return None

    def resolvable(self, node):
        if isinstance(node, Simple):
            return bool(self.u.providers(node)[0])
        if node.op in ("with", "without"):
            s = self.provider_set(node)
            return bool(s) if s is not None else all(self.resolvable(x) for x in node.args)
        if node.op == "and":
            return all(self.resolvable(x) for x in node.args)
        if node.op == "or":
            return any(self.resolvable(x) for x in node.args)
        return True  # conditionals never block

    def require(self, node, why, decide=False):
        """Make sure node is satisfied.  Requirements with a single possible
        provider are applied at once; ones that need a choice are deferred
        until nothing else is left (like libsolv's unit propagation before
        decisions), unless decide=True."""
        if self.satisfied(node) and not (isinstance(node, Rich) and node.op in ("if", "unless")):
            return
        if isinstance(node, Simple):
            found, how = self.u.providers(node)
            if not found:
                self.fail(node.text, why)
                return
            if len(found) > 1 and not decide:
                self.deferred.append((node, why))
                return
            if how:
                self.notes.append("%s -> %s (%s)" % (node.text, ",".join(found), how))
            self.add(self.pick(node.text, node.name, found, why), why)
            return
        op, a = node.op, node.args
        if op == "and":
            for x in a:
                self.require(x, why, decide)
        elif op == "or":
            alts = [x for x in a if self.resolvable(x)]
            if not alts:
                self.fail(node.text, why)
            elif len(alts) > 1 and not decide:
                self.deferred.append((node, why))
            else:
                self.require(alts[0], why, decide)
        elif op in ("with", "without"):
            s = self.provider_set(node)
            if s is None:
                for x in (a if op == "with" else a[:1]):
                    self.require(x, why, decide)
            elif not s:
                self.fail(node.text, why)
            elif len(s) > 1 and not decide:
                self.deferred.append((node, why))
            else:
                first = a[0]
                while isinstance(first, Rich):
                    first = first.args[0]
                self.add(self.pick(node.text, first.name, sorted(s), why), why)
        elif op in ("if", "unless"):
            self.conditionals.append((node, why))
        else:
            raise AssertionError(op)

    def request(self, node, why):
        """A top-level job (dnf install arg / builddep BuildRequires): like
        require(), but a package whose *name* matches a simple dep (and whose
        EVR satisfies it) is taken before considering other providers, as dnf
        does for "dnf install kernel" (kernel, not kernel-core)."""
        if isinstance(node, Simple) and not self.satisfied(node):
            named = [k for k in sorted(self.u.by_name.get(node.name, []))
                     if ranges_overlap("=", UL.parse_evr(self.u.deps[k]["evr"]),
                                       node.op, node.evr)]
            if named:
                self.add(named[0], why)
                return
        self.require(node, why)

    def run_queue(self):
        while self.queue:
            key = self.queue.popleft()
            for r in self.u.requires(key):
                self.require(r, key)

    def settle(self):
        """Drain the queue, re-evaluate conditionals, then take deferred
        decisions one at a time (FIFO), until a fixpoint."""
        while True:
            self.run_queue()
            changed = False
            pending, self.conditionals = self.conditionals, []
            for node, why in pending:
                cond_true = self.satisfied(node.args[1])
                want = node.args[0] if (cond_true == (node.op == "if")) else node.args[2]
                before = len(self.selected)
                if want is not None and not self.satisfied(want):
                    self.require(want, why)
                if len(self.selected) != before:
                    changed = True
                self.conditionals.append((node, why))
            if changed or self.queue:
                continue
            if self.deferred:
                node, why = self.deferred.popleft()
                self.require(node, why, decide=True)
                continue
            break

    def install_names(self, names, why):
        """dnf install <names>: names are package names or provides."""
        for n in names:
            keys = sorted(self.u.by_name.get(n, []))
            if keys:
                for k in keys:
                    self.add(k, why)
            else:
                self.request(parse_dep(n), why)
        self.settle()

    def conflicts(self):
        out = []
        sel = set(self.selected)
        for k in sorted(sel):
            for c in self.u.deps[k]["conflicts"]:
                node = parse_dep(c)
                if isinstance(node, Simple):
                    hit = [x for x in self.u.providers(node)[0] if x in sel and x != k]
                    if hit:
                        out.append((k, c, hit))
        return out

    def obsoleted(self):
        """Selected packages that some repo package obsoletes."""
        out = []
        sel = set(self.selected)
        for k, d in self.u.deps.items():
            for o in d["obsoletes"]:
                node = parse_dep(o)
                if not isinstance(node, Simple):
                    continue
                for s in self.u.by_name.get(node.name, []):
                    if s in sel and s != k:
                        evr = UL.parse_evr(self.u.deps[s]["evr"])
                        if ranges_overlap("=", evr, node.op, node.evr):
                            out.append((s, k, o))
        return sorted(set(out))


def resolve(uni, srpm, buildsys, single=False):
    if srpm not in uni.srpms:
        raise SystemExit("unknown SRPM %r" % srpm)
    r = Resolver(uni)
    if buildsys:
        if single:
            # one dnf transaction for buildsys + BuildRequires (for comparing
            # against `dnf install --assumeno ...`); mock uses two.
            for n in buildsys:
                for k in sorted(uni.by_name.get(n, [])):
                    r.add(k, "@buildsys")
        else:
            r.install_names(buildsys, "@buildsys")
    base = set(r.selected)
    brs = uni.srpms[srpm]["buildRequires"]
    # dnf builddep: all BuildRequires in one transaction
    for d in brs:
        r.request(parse_dep(d), "BR:" + d)
    r.settle()
    br_map = {}
    for d in brs:
        hit = sorted({k for leaf in _wanted_leaves(parse_dep(d))
                      for k in uni.providers(leaf)[0] if k in r.selected})
        br_map[d] = hit
    return r, base, br_map


def srpms_of(uni, keys):
    return sorted({uni.rpms[k]["srpm"] for k in keys})


def recursive_closure(uni, srpm, buildsys):
    """Fixpoint: SRPMs needed to build every SRPM in the buildroot closure."""
    seen, todo, unres = set(), [srpm], {}
    while todo:
        s = todo.pop()
        if s in seen:
            continue
        seen.add(s)
        if s not in uni.srpms:
            unres[s] = ["(no SRPM in lock)"]
            continue
        r, _, _ = resolve(uni, s, buildsys)
        if r.unresolved:
            unres[s] = sorted({d for d, _ in r.unresolved})
        for t in srpms_of(uni, r.selected):
            if t not in seen:
                todo.append(t)
    return sorted(seen), unres


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def nevra(uni, k):
    r = uni.rpms[k]
    return "%s-%s.%s" % (r["name"], UL.format_evr(r["epoch"], r["version"], r["release"]), r["arch"])


def to_json(uni, srpm, r, base, br_map, rec):
    sel = sorted(r.selected)
    doc = {
        "srpm": srpm,
        "buildsys": sorted(base),
        "buildRequires": br_map,
        "packages": [{"key": k, "nevra": nevra(uni, k), "repo": uni.rpms[k]["repo"],
                      "srpm": uni.rpms[k]["srpm"], "size": uni.rpms[k]["size"],
                      "why": r.selected[k]} for k in sel],
        "srpms": srpms_of(uni, sel),
        "unresolved": [{"dep": d, "requiredBy": w} for d, w in r.unresolved],
        "choices": [{"dep": d, "picked": p, "alternatives": alt, "requiredBy": w}
                    for d, p, alt, w in r.choices],
        "notes": r.notes,
        "conflicts": [{"pkg": k, "conflicts": c, "with": h} for k, c, h in r.conflicts()],
        "obsoleted": [{"pkg": s, "by": k, "obsoletes": o} for s, k, o in r.obsoleted()],
    }
    if rec is not None:
        doc["recursive"] = {"srpms": rec[0], "unresolved": rec[1]}
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


def to_md(uni, srpm, r, base, br_map, rec, setup_name, buildsys):
    s = uni.srpms[srpm]
    sel = sorted(r.selected)
    by_srpm = collections.defaultdict(list)
    for k in sel:
        by_srpm[uni.rpms[k]["srpm"]].append(k)
    br_only = [k for k in sel if k not in base]
    total = sum(uni.rpms[k]["size"] for k in sel)
    repos = collections.Counter(uni.rpms[k]["repo"] for k in sel)
    L = []
    w = L.append
    w("# Buildroot closure for `%s-%s-%s`" % (srpm, s["version"], s["release"]))
    w("")
    w("Generated by `tools/resolve-buildrequires.py %s --format md%s` from the "
      "lock files in `lock/rocky-<rel>/` (Rocky BaseOS + AppStream + CRB, x86_64/noarch, "
      "newest EVR only). Do not edit by hand." % (srpm, " --recursive" if rec else ""))
    w("")
    w("## Summary")
    w("")
    w("| | count |")
    w("|---|---|")
    w("| BuildRequires in SRPM header | %d |" % len(s["buildRequires"]))
    w("| buildsys packages requested (`%s` chroot_setup_cmd) | %d |" % (setup_name, len(buildsys)))
    w("| binary packages after transaction 1 (buildsys closure) | %d |" % len(base))
    w("| binary packages added by BuildRequires (transaction 2) | %d |" % len(br_only))
    w("| **binary packages in buildroot** | **%d** |" % len(sel))
    w("| **source RPMs those come from** | **%d** |" % len(by_srpm))
    w("| download size of the binary RPMs | %.1f MiB |" % (total / 1048576.0))
    w("| by repo | %s |" % ", ".join("%s %d" % kv for kv in sorted(repos.items())))
    w("| unresolved deps | %d |" % len(r.unresolved))
    if rec is not None:
        w("| **SRPMs in the recursive build closure** (every SRPM needed to build every buildroot SRPM, to a fixpoint) | **%d** |" % len(rec[0]))
    w("")
    w("Model: mock rocky-10 = transaction 1 `dnf install %s`, then transaction 2 "
      "`dnf builddep` of the SRPM, `install_weak_deps=0`. See the docstring of "
      "`tools/resolve-buildrequires.py` for the resolution rules and what is not emulated."
      % " ".join(buildsys))
    w("")
    w("## BuildRequires -> provider")
    w("")
    w("| BuildRequires | resolved to |")
    w("|---|---|")
    for d in s["buildRequires"]:
        w("| `%s` | %s |" % (d, ", ".join("`%s`" % x for x in br_map.get(d, [])) or "**unresolved**"))
    w("")
    if r.unresolved:
        w("## Unresolved")
        w("")
        for d, why in r.unresolved:
            w("- `%s` (required by `%s`)" % (d, why))
        w("")
    if r.choices:
        w("## Ambiguous provider choices (heuristic picks; review)")
        w("")
        for d, p, alt, why in r.choices:
            w("- `%s` -> `%s` (alternatives: %s; required by `%s`)"
              % (d, p, ", ".join("`%s`" % a for a in alt[:6]) + (" ..." if len(alt) > 6 else ""), why))
        w("")
    notes = r.notes
    cf = r.conflicts()
    ob = r.obsoleted()
    if notes or cf or ob:
        w("## Notes")
        w("")
        for n in notes:
            w("- file dep fallback: `%s`" % n)
        for k, c, h in cf:
            w("- conflict: `%s` conflicts `%s` with %s" % (k, c, h))
        for sk, k, o in ob:
            w("- obsoleted: `%s` is obsoleted by `%s` (`%s`)" % (sk, k, o))
        w("")
    w("## Source RPMs (%d) and the binary packages each contributes" % len(by_srpm))
    w("")
    w("`*` = also in the transaction-1 buildsys closure.")
    w("")
    w("| SRPM | repo | binary packages |")
    w("|---|---|---|")
    for sname in sorted(by_srpm):
        ent = uni.srpms.get(sname)
        repo = ent["repo"] if ent else "?"
        pk = ", ".join(("%s%s" % (uni.rpms[k]["name"], "*" if k in base else "")) for k in by_srpm[sname])
        w("| `%s` | %s | %s |" % (sname, repo, pk))
    w("")
    w("## Binary packages (%d)" % len(sel))
    w("")
    w("<details><summary>full NEVRA list</summary>")
    w("")
    for k in sel:
        w("- `%s` (%s)" % (nevra(uni, k), uni.rpms[k]["repo"]))
    w("")
    w("</details>")
    w("")
    if rec is not None:
        w("## Recursive build closure (%d SRPMs)" % len(rec[0]))
        w("")
        w("Every SRPM reachable by repeatedly taking an SRPM's buildroot closure "
          "and adding the SRPMs of all its packages. This is (an upper bound on) what "
          "must be rebuilt from source for a buildroot made only of our own builds, "
          "ignoring bootstrap cycles (which stage0 breaks with nixpkgs tools).")
        w("")
        w(", ".join("`%s`" % x for x in rec[0]))
        w("")
        if rec[1]:
            w("Unresolved deps met while computing it:")
            w("")
            for k in sorted(rec[1]):
                w("- `%s`: %s" % (k, ", ".join("`%s`" % d for d in rec[1][k])))
            w("")
    return "\n".join(L)


def to_text(uni, srpm, r, base, br_map, rec):
    sel = sorted(r.selected)
    out = ["%s: %d packages (%d buildsys), %d SRPMs, %d unresolved"
           % (srpm, len(sel), len(base), len(srpms_of(uni, sel)), len(r.unresolved))]
    out += ["  " + nevra(uni, k) for k in sel]
    out.append("SRPMs: " + " ".join(srpms_of(uni, sel)))
    for d, why in r.unresolved:
        out.append("UNRESOLVED %s (by %s)" % (d, why))
    if rec is not None:
        out.append("recursive closure: %d SRPMs: %s" % (len(rec[0]), " ".join(rec[0])))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("srpm")
    ap.add_argument("--release", default=UL.DEFAULT_RELEASE)
    ap.add_argument("--lock", default="lock", help="lock root (default ./lock)")
    ap.add_argument("--format", choices=("text", "json", "md"), default="text")
    ap.add_argument("--mock-config", choices=sorted(MOCK_CHROOT_SETUP), default="rocky-10")
    ap.add_argument("--no-buildsys", action="store_true",
                    help="only BuildRequires (no chroot_setup_cmd packages)")
    ap.add_argument("--recursive", action="store_true",
                    help="also compute the recursive SRPM build closure")
    ap.add_argument("--single-transaction", action="store_true",
                    help="resolve buildsys + BuildRequires as one dnf transaction "
                         "(for comparison with `dnf install --assumeno`)")
    ap.add_argument("-o", "--output", help="write to file instead of stdout")
    args = ap.parse_args(argv)

    lockdir = os.path.join(args.lock, "rocky-%s" % args.release)
    if not os.path.isfile(os.path.join(lockdir, "deps.json.gz")):
        raise SystemExit("no lockfiles in %s: run from the repository root or pass --lock"
                         % lockdir)
    uni = Universe(lockdir)
    buildsys = [] if args.no_buildsys else MOCK_CHROOT_SETUP[args.mock_config].split()
    r, base, br_map = resolve(uni, args.srpm, buildsys, args.single_transaction)
    rec = recursive_closure(uni, args.srpm, buildsys) if args.recursive else None
    if args.format == "json":
        text = to_json(uni, args.srpm, r, base, br_map, rec)
    elif args.format == "md":
        text = to_md(uni, args.srpm, r, base, br_map, rec, args.mock_config, buildsys)
    else:
        text = to_text(uni, args.srpm, r, base, br_map, rec)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
