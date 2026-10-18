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

Output (deterministic; one SRPM / provider per line):

    {"format": 1, "release": "10.2", "model": "...",
     "srpms": {"<srpm>": {"buildRequires": {"<BR as in the header>": ["<rpm name>", ...]},
                          "inputs": ["<rpm name>", ...],   # union of the above
                          "unresolved": ["<BR>", ...]}},   # only when non-empty
     "providers": {"<rpm name>": {"srpm": "...", "arch": "x86_64|noarch",
                                  "tags": ["lib", "macro", "tool"] | ["other"]}}}

Tags (from the official file lists, tools/lock_filelists.py):
    tool   ships a file in /usr/bin, /usr/sbin (a PATH tool: nativeBuildInputs)
    lib    -devel/-static/-headers name, or ships a shared library
           /usr/lib{,64}/lib*.so* (buildInputs; may leave references)
    macro  ships rpm macros (/usr/lib/rpm/macros.d, ...): rpm config of the build
    other  none of these (data, language modules, ...)
"""

import argparse
import importlib.util
import json
import os
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
         "BuildRequires, install_weak_deps=0; direct providers only (no Requires closure)")


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


def selftest():
    """Tag rules.  Returns the number of failures."""
    cases = [("foo-devel", {}, ["lib"]), ("foo", {"bin": True, "solib": True}, ["lib", "tool"]),
             ("redhat-rpm-config", {"macro": True}, ["macro"]), ("foo-data", {"usr": 5}, ["other"]),
             ("kernel-headers", {}, ["lib"]), ("make", {"bin": True}, ["tool"])]
    bad = 0
    for name, summ, want in cases:
        got = tags_for(name, summ)
        if got != want:
            UL.log("FAIL tags_for(%r, %r) = %r, want %r" % (name, summ, got, want))
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
    """Returns the builddeps document.  summary: lock_filelists summary."""
    log = log or UL.log
    uni = RBR.Universe(lockdir)
    if buildsys is None:
        buildsys = RBR.MOCK_CHROOT_SETUP["rocky-10"].split()
    srpms, used = {}, set()
    for s in sorted(uni.srpms):
        r, _base, _br_map = RBR.resolve(uni, s, buildsys)
        brs = {}
        unresolved = []
        for dep in uni.srpms[s]["buildRequires"]:
            node = RBR.parse_dep(dep)
            keys = {k for leaf in active_leaves(r, node)
                    for k in uni.providers(leaf)[0] if k in r.selected}
            names = sorted({uni.rpms[k]["name"] for k in keys})
            brs[dep] = names
            used.update(keys)
            if not r.satisfied(node):
                unresolved.append(dep)
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
    n_unres = sum(1 for e in srpms.values() if "unresolved" in e)
    log("builddeps: %d SRPMs, %d direct providers, %d SRPMs with unresolved BuildRequires"
        % (len(srpms), len(providers), n_unres))
    return {"format": 1, "release": os.path.basename(lockdir).replace("rocky-", ""),
            "model": MODEL, "srpms": srpms, "providers": providers}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lock", default="lock")
    ap.add_argument("--release", default=UL.DEFAULT_RELEASE)
    ap.add_argument("--cache-dir", default=None)
    args = ap.parse_args(argv)
    lockdir = os.path.join(args.lock, "rocky-%s" % args.release)
    cache = args.cache_dir or os.path.join(".cache", "repodata", args.release)
    with open(os.path.join(lockdir, "rpms.json")) as f:
        rpms_doc = json.load(f)
    summary = lock_filelists.file_summary(UL, rpms_doc, cache)
    doc = generate(lockdir, summary)
    p = os.path.join(lockdir, "builddeps.json")
    UL.write_text(p, UL.dump_one_per_line(doc))
    UL.log("wrote %s (%d bytes)" % (p, os.path.getsize(p)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
