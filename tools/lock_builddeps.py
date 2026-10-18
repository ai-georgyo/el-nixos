"""builddeps.json: the direct providers of every SRPM's BuildRequires.

Helper module of tools/update-lock.py (design: docs/nix-native-design.md
§5.6, §8.2); standard library only.  Also runnable on its own:

    python3 -I tools/lock_builddeps.py [--lock lock] [--release 10.2] [--cache-dir DIR]

For every SRPM of srpms.json, the BuildRequires of its header are resolved
with the resolver of tools/resolve-buildrequires.py (validated against
dnf5) in the mock rocky-10 model: transaction 1 = the buildsys packages,
transaction 2 = ``dnf builddep``, ``install_weak_deps=0``.  For each
BuildRequire the *direct* providers are the selected packages that provide
it (file, rich and virtual deps included); the Requires closure is not
listed (in the Nix-native build the runtime closure comes from references,
and the stdenv is implicit).

What no published RPM provides is then matched against the *unshipped*
subpackages of subpackages.json (design §0.4.4, §3.2: they are outputs too):
a simple dep matches an unshipped name (shipped by no SRPM) if the SRPM's
EVR satisfies its version range; ``or`` takes the first branch that
matches, ``and``/``with`` need all of theirs.  Provides other than the
package name (``pkgconfig(...)``, files) are not known for unshipped
packages, so such BuildRequires stay unresolved.

Output (deterministic; one SRPM / provider per line):

    {"format": 1, "release": "10.2", "model": "...",
     "srpms": {"<srpm>": {"buildRequires": {"<BR as in the header>": ["<rpm name>", ...]},
                          "inputs": ["<rpm name>", ...],   # union of the above
                          "unresolved": ["<BR>", ...]}},   # only when non-empty
     "providers": {"<rpm name>": {"srpm": "...", "arch": "x86_64|noarch",
                                  "tags": ["lib", "macro", "tool"] | ["other"],
                                  "unshipped": true}},     # only for unshipped subpackages
     "filelists": {"<repo>": "<sha256 of the filelists.xml the tags come from>"},
     "stats": {...}}

Tags (from the official file lists, tools/lock_filelists.py):
    tool   ships a file in /usr/bin, /usr/sbin (a PATH tool: nativeBuildInputs)
    lib    -devel/-static/-headers name, or ships a shared library
           /usr/lib{,64}/lib*.so* (buildInputs; may leave references)
    macro  ships rpm macros (/usr/lib/rpm/macros.d, ...): rpm config of the build
    other  none of these (data, language modules, ...)
Unshipped subpackages have no file list: their tags come from the name
(-devel/-static/-headers/-libs or lib* -> lib, else other).
"""

import argparse
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)  # -I drops the script dir from sys.path


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_here, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


UL = _load("update_lock", "update-lock.py")
RBR = _load("resolve_buildrequires", "resolve-buildrequires.py")
import lock_filelists  # noqa: E402

MODEL = ("mock rocky-10: buildsys transaction, then dnf builddep of the SRPM header "
         "BuildRequires, install_weak_deps=0; direct providers only (no Requires closure); "
         "the rest matched by name against unshipped subpackages (subpackages.json)")
UNSHIPPED_LIB = re.compile(r"(-devel|-static|-headers|-libs)$|^lib")


def tags_for(name, summary):
    s = summary or {}
    t = []
    if name.endswith(("-devel", "-static", "-headers")) or s.get("solib"):
        t.append("lib")
    if s.get("macro"):
        t.append("macro")
    if s.get("bin"):
        t.append("tool")
    return t or ["other"]


def unshipped_tags(name):
    return ["lib"] if UNSHIPPED_LIB.search(name) else ["other"]


def unshipped_index(subdoc, shipped_names, log):
    """{name: (srpm, evr tuple, arch)} for the subpackages no SRPM ships.  A
    name built (unshipped) by two SRPMs goes to the alphabetically first."""
    idx = {}
    for srpm in sorted(subdoc.get("srpms", {})):
        e = subdoc["srpms"][srpm]
        noarch = set(e.get("noarch", []))
        for n in e["names"]:
            if e["shipped"].get(n) or n in shipped_names:
                continue
            if n in idx:
                log("builddeps: unshipped %s is built by %s and %s; using %s"
                    % (n, idx[n][0], srpm, idx[n][0]))
                continue
            idx[n] = (srpm, UL.parse_evr(e["evr"]), "noarch" if n in noarch else "x86_64")
    return idx


def unshipped_match(r, node, idx):
    """Unshipped subpackage names that satisfy BuildRequire `node` (which
    the published RPMs do not satisfy), or None.  Parts the selection r
    already satisfies contribute nothing."""
    if r.satisfied(node):
        return []
    if isinstance(node, RBR.Simple):
        hit = idx.get(node.name)
        if hit and RBR.ranges_overlap("=", hit[1], node.op, node.evr):
            return [node.name]
        return None
    op, a = node.op, node.args
    if op in ("if", "unless"):
        take = r.satisfied(a[1]) == (op == "if")
        branch = a[0] if take else a[2]
        return unshipped_match(r, branch, idx) if branch is not None else []
    if op == "without":
        return unshipped_match(r, a[0], idx)
    if op == "or":
        for x in a:
            m = unshipped_match(r, x, idx)
            if m is not None:
                return m
        return None
    out = []  # and, with
    for x in a:
        m = unshipped_match(r, x, idx)
        if m is None:
            return None
        out.extend(m)
    return out


def selftest():
    """Tag rules and the unshipped fallback.  Returns the number of failures."""
    cases = [("foo-devel", {}, ["lib"]), ("foo", {"bin": True, "solib": True}, ["lib", "tool"]),
             ("redhat-rpm-config", {"macro": True}, ["macro"]), ("foo-data", {"usr": 5}, ["other"]),
             ("kernel-headers", {}, ["lib"]), ("make", {"bin": True}, ["tool"])]
    bad = 0
    for name, summ, want in cases:
        got = tags_for(name, summ)
        if got != want:
            UL.log("FAIL tags_for(%r, %r) = %r, want %r" % (name, summ, got, want))
            bad += 1

    class Sel:  # resolver stand-in: only the package "have" is selected
        def satisfied(self, node):
            if isinstance(node, RBR.Simple):
                return node.name == "have"
            return RBR.Resolver.satisfied(self, node)

        def provider_set(self, node):
            return None
    idx = {"glibc32": ("glibc", UL.parse_evr("2.39-1"), "x86_64"),
           "libfoo-devel": ("libfoo", UL.parse_evr("1.0-1"), "x86_64")}
    for dep, want in [("(glibc32 or glibc-devel(x86-32))", ["glibc32"]),
                      ("libfoo-devel >= 1.1", None), ("libfoo-devel >= 0.9", ["libfoo-devel"]),
                      ("(have and libfoo-devel)", ["libfoo-devel"]),
                      ("(libfoo-devel and nope)", None), ("(nope if have)", None),
                      ("(nope if nope2)", []), ("pkgconfig(foo)", None)]:
        got = unshipped_match(Sel(), RBR.parse_dep(dep), idx)
        if got != want:
            UL.log("FAIL unshipped_match(%r) = %r, want %r" % (dep, got, want))
            bad += 1
    return bad


def active_leaves(r, node):
    """The simple deps a BuildRequire asks for, given the final selection:
    a conditional contributes only its active branch (``(A if B)`` with B
    unsatisfied asks for nothing), ``without`` only its left side."""
    if isinstance(node, RBR.Simple):
        return [node]
    op, a = node.op, node.args
    if op in ("if", "unless"):
        take = r.satisfied(a[1]) == (op == "if")
        branch = a[0] if take else a[2]
        return active_leaves(r, branch) if branch is not None else []
    if op == "without":
        return active_leaves(r, a[0])
    return [x for y in a for x in active_leaves(r, y)]


def generate(lockdir, summary, buildsys=None, log=None):
    """Returns the builddeps document.  summary: lock_filelists summary.
    Reads lockdir/subpackages.json (if present) for the unshipped fallback."""
    log = log or UL.log
    uni = RBR.Universe(lockdir)
    if buildsys is None:
        buildsys = RBR.MOCK_CHROOT_SETUP["rocky-10"].split()
    sp = os.path.join(lockdir, "subpackages.json")
    subdoc = {}
    if os.path.exists(sp):
        with open(sp) as f:
            subdoc = json.load(f)
    else:
        log("builddeps: no %s: unshipped subpackages are not considered" % sp)
    idx = unshipped_index(subdoc, {r["name"] for r in uni.rpms.values()}, log)
    srpms, used, used_unshipped = {}, set(), set()
    n_fallback = 0
    for s in sorted(uni.srpms):
        r, _base, _br_map = RBR.resolve(uni, s, buildsys)
        brs = {}
        unresolved = []
        for dep in uni.srpms[s]["buildRequires"]:
            node = RBR.parse_dep(dep)
            keys = {k for leaf in active_leaves(r, node)
                    for k in uni.providers(leaf)[0] if k in r.selected}
            names = {uni.rpms[k]["name"] for k in keys}
            used.update(keys)
            if not r.satisfied(node):
                extra = unshipped_match(r, node, idx)
                if extra is None:
                    unresolved.append(dep)
                else:
                    n_fallback += 1
                    names.update(extra)
                    used_unshipped.update(extra)
            brs[dep] = sorted(names)
        ent = {"buildRequires": brs,
               "inputs": sorted({n for ns in brs.values() for n in ns})}
        if unresolved:
            ent["unresolved"] = sorted(unresolved)
        srpms[s] = ent
    providers = {}
    for k in sorted(used):
        r = uni.rpms[k]
        providers[r["name"]] = {"srpm": r["srpm"], "arch": r["arch"],
                                "tags": tags_for(r["name"], summary.get(k))}
    for n in sorted(used_unshipped):
        srpm, _evr, arch = idx[n]
        providers[n] = {"srpm": srpm, "arch": arch, "tags": unshipped_tags(n), "unshipped": True}
    unres = [d for e in srpms.values() for d in e.get("unresolved", [])]
    stats = {"srpms": len(srpms), "providers": len(providers),
             "unshippedProviders": len(used_unshipped),
             "resolvedByUnshipped": n_fallback,
             "unresolved": len(unres), "unresolvedDistinct": len(set(unres)),
             "srpmsWithUnresolved": sum(1 for e in srpms.values() if "unresolved" in e)}
    log("builddeps: %s" % json.dumps(stats, sort_keys=True))
    return {"format": 1, "release": os.path.basename(lockdir).replace("rocky-", ""),
            "model": MODEL, "srpms": srpms, "providers": providers,
            "filelists": lock_filelists.provenance(summary), "stats": stats}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lock", default="lock")
    ap.add_argument("--release", default=UL.DEFAULT_RELEASE)
    ap.add_argument("--cache-dir", default=None)
    ap.add_argument("--allow-missing-filelists", action="store_true",
                    help="warn instead of failing when the filelists do not match the lock")
    args = ap.parse_args(argv)
    lockdir = os.path.join(args.lock, "rocky-%s" % args.release)
    cache = args.cache_dir or os.path.join(".cache", "repodata", args.release)
    with open(os.path.join(lockdir, "rpms.json")) as f:
        rpms_doc = json.load(f)
    try:
        summary = lock_filelists.file_summary(UL, rpms_doc, cache,
                                              allow_missing=args.allow_missing_filelists)
    except lock_filelists.FilelistsError as e:
        UL.log("error: %s" % e)
        return 1
    doc = generate(lockdir, summary)
    p = os.path.join(lockdir, "builddeps.json")
    UL.write_text(p, UL.dump_one_per_line(doc))
    UL.log("wrote %s (%d bytes)" % (p, os.path.getsize(p)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
