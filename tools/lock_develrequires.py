"""develrequires.json: the cross-SRPM Requires of every shipped -devel package.

Helper module of tools/update-lock.py (design: docs/nix-native-design.md
§5.6); standard library only, offline (reads the committed lock files).
Also runnable on its own:

    python3 -I tools/lock_develrequires.py [--lock lock] [--release 10.2]
    python3 -I tools/lock_develrequires.py --self-test

Why: mock installs the Requires closure of every BuildRequire, so a spec
that BuildRequires foo-devel also gets what foo-devel Requires from other
SRPMs (glibc-devel -> kernel-headers, libxcrypt-devel: <crypt.h>).
builddeps.json lists the *direct* providers only; mkStage's
resolveBuildDeps follows this file to propagate the -devel chain at
evaluation time (no IFD: Nix cannot read deps.json.gz).

For every package of rpms.json/deps.json.gz whose name ends in -devel
(x86_64 or noarch), each Requires entry is resolved with the resolver of
tools/resolve-buildrequires.py (Universe.providers: provides and file
lists); providers of the same SRPM are dropped (siblings: the partition's
outputRequires covers them), and so are the requirer's own provides.  One
provider name per Requires entry: the only one, else the one named like the
dependency, else the alphabetically first (listed under `ambiguous`).
Rich (boolean) Requires are listed under `rich` and not resolved.

Output (deterministic; one package per line):

    {"format": 1, "release": "10.2", "model": "...",
     "devel": {"<devel rpm>": ["<provider rpm name>", ...]},   # cross-SRPM only, sorted
     "providers": {"<rpm name>": "<srpm>"},                    # every name above
     "ambiguous": {"<devel rpm>": {"<Requires>": ["<rpm>", ...]}},
     "rich": {"<devel rpm>": ["<Requires>", ...]},
     "unresolved": {"<devel rpm>": ["<Requires>", ...]},
     "stats": {...}}
"""

import argparse
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_here, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


UL = _load("update_lock", "update-lock.py")
RBR = _load("resolve_buildrequires", "resolve-buildrequires.py")

MODEL = ("Requires of every shipped -devel package (x86_64/noarch), resolved against the lock's "
         "provides and file lists; same-SRPM providers and self-provides dropped; one provider per "
         "Requires (unique, else the one named like the dependency, else the first)")


def pick(dep_name, names):
    """one provider name of several (see the module docstring)"""
    names = sorted(names)
    if len(names) == 1:
        return names[0], False
    if dep_name in names:
        return dep_name, True
    return names[0], True


def generate(uni):
    devel, providers, ambiguous, rich, unresolved = {}, {}, {}, {}, {}
    for key in sorted(uni.deps):
        r = uni.rpms[key]
        name, srpm = r["name"], r["srpm"]
        if not name.endswith("-devel") or r["arch"] not in ("x86_64", "noarch"):
            continue
        own = {RBR.parse_dep(p).name for p in uni.deps[key]["provides"]}
        found = set()
        for node in uni.requires(key):
            text = str(node)
            if not isinstance(node, RBR.Simple):
                rich.setdefault(name, []).append(text)
                continue
            if node.name in own or node.name.startswith("rpmlib("):
                continue
            keys, _how = uni.providers(node)
            keys = [k for k in keys if uni.rpms[k]["arch"] in ("x86_64", "noarch")]
            if not keys:
                unresolved.setdefault(name, []).append(text)
                continue
            if any(uni.rpms[k]["srpm"] == srpm for k in keys):
                continue                     # a sibling satisfies it
            names = {uni.rpms[k]["name"] for k in keys}
            p, amb = pick(node.name, names)
            if amb:
                ambiguous.setdefault(name, {})[text] = sorted(names)
            found.add(p)
            providers[p] = next(uni.rpms[k]["srpm"] for k in keys if uni.rpms[k]["name"] == p)
        if found:
            if name in devel and set(devel[name]) != found:
                found |= set(devel[name])     # two arches of one name: union
            devel[name] = sorted(found)
    stats = {"develPackages": len(devel), "providers": len(providers),
             "ambiguous": sum(len(v) for v in ambiguous.values()),
             "rich": sum(len(v) for v in rich.values()),
             "unresolved": sum(len(v) for v in unresolved.values())}
    return {"format": 1, "model": MODEL, "devel": devel, "providers": providers,
            "ambiguous": ambiguous, "rich": {k: sorted(set(v)) for k, v in rich.items()},
            "unresolved": {k: sorted(set(v)) for k, v in unresolved.items()}, "stats": stats}


def write(lockdir, log=None):
    log = log or UL.log
    doc = generate(RBR.Universe(lockdir))
    doc["release"] = os.path.basename(lockdir).replace("rocky-", "")
    p = os.path.join(lockdir, "develrequires.json")
    UL.write_text(p, UL.dump_one_per_line(doc))
    log("wrote %s: %s" % (p, json.dumps(doc["stats"], sort_keys=True)))
    return doc


def self_test():
    bad = 0
    for dep, names, want in [("a", {"a"}, ("a", False)), ("x", {"b", "a"}, ("a", True)),
                             ("b", {"a", "b"}, ("b", True))]:
        got = pick(dep, names)
        if got != want:
            UL.log("FAIL pick(%r, %r) = %r, want %r" % (dep, names, got, want))
            bad += 1
    return bad == 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lock", default="lock")
    ap.add_argument("--release", default=UL.DEFAULT_RELEASE)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    if not self_test():
        return 1
    if args.self_test:
        return 0
    write(os.path.join(args.lock, "rocky-%s" % args.release))
    return 0


if __name__ == "__main__":
    sys.exit(main())
