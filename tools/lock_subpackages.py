#!/usr/bin/env python3
"""subpackages.json: the subpackages every SRPM's spec builds (design §3.1, §3.2).

Usage (from the repository root; needs nix and the flake):

    python3 -I tools/lock_subpackages.py --seed            # the seed set (nn.lockgen.seed)
    python3 -I tools/lock_subpackages.py --stale           # everything missing or out of date
    python3 -I tools/lock_subpackages.py glibc krb5        # these SRPMs
    python3 -I tools/lock_subpackages.py --all --no-build  # collect what is already built
    ... [-- NIX-BUILD-ARGS]                                # default: --cores 6 --max-jobs 2

1. ``nix eval`` of ``legacyPackages.x86_64-linux.nn.lockgen.paths`` for the
   selected SRPMs (drv and out path of ``nn.lockgen.subpackages.<srpm>``:
   ``rpmspec -q`` of the exact locked SRPM with the stage0 rpm and Rocky's
   macro packages, lib/rocky/parts/lockgen.nix).
2. One ``nix build --keep-going --no-link --stdin`` of the missing ones.
   Results are ordinary derivation outputs, so every run is incremental:
   re-running costs nothing for what is built, and a lock bump only
   re-queries SRPMs whose lock entry changed.
3. The results are folded into lock/rocky-<rel>/subpackages.json; SRPMs not
   selected keep their previous entry (dropped if the lock no longer has
   them at that EVR).  So does a selected SRPM whose result is not in the
   store with --no-build: only collected results replace entries.

Every entry (and failure) records ``lockgen``, the hash of the query
derivation that produced it.  --stale evaluates all queries and selects
the SRPMs whose entry is missing, has another EVR, failed to build, or came
from another derivation (lockgen buildroot, query script, SRPM or the
bootstrap nixpkgs changed).  After a run, regenerate builddeps.json and
order.json (``python3 -I tools/update-lock.py --derived-only``): builddeps
resolves BuildRequires against the unshipped names.

Per SRPM (one line each, sorted keys):

    "<srpm>": {"evr": "<[E:]V-R>",
               "lockgen": "<hash of the nn.lockgen.subpackages.<srpm> .drv>",
               "names": [...],          # spec order, rpmspec -q --builtrpms, debug packages excluded
               "debug": [...],          # -debuginfo/-debugsource/-debuginfo-common-* names
               "noarch": [...],         # names built as noarch (the rest: x86_64)
               "shipped": {"<name>": true|false},   # in rpms.json bySrpm
               "prefix": "<name>",      # the subpackage compiled with %_prefix = $out
               "prefixRule": "eponymous" | "libs" | "stem" | "stem-libs" | "usr-files" | "first",
               "usrFiles": {...},       # prefixRule usr-files/first: /usr file counts of the shipped names
               "notBuilt": [...],       # declared %package without %files (if any;
                                        # "notBuiltUnknown": true if that query failed)
               "shippedMissing": [...], # shipped from this SRPM but not built by the spec (if any)
               "exclusiveArch": [...], "excludeArch": [...]}   # (if any)

Prefix rule (choose_prefix): the eponymous subpackage, else ``<srpm>-libs``,
else the same two for the SRPM name without its version (python3.12 ->
python3), else the shipped subpackage owning most /usr files in the
official filelists (ties: spec order) that is not a -test/-doc/-javadoc/
-devel/... one, else the first name.  Failures go to ``"failed": {"<srpm>":
{"evr", "lockgen", "kind": "rpmspec"|"build"|"evr", "errors"}}`` instead of
aborting.

Top level: ``duplicateNames`` = {"<name>": [srpms]} for names more than one
SRPM builds (rubygem-racc: ruby builds it unshipped, rubygem-racc ships it);
the ``rpm.<name>`` alias should point at the SRPM whose ``shipped`` is true.
``filelists`` = the filelists.xml checksums the shipped/prefix data came from.
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)  # -I drops the script dir from sys.path
_spec = importlib.util.spec_from_file_location("update_lock", os.path.join(_here, "update-lock.py"))
UL = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(UL)
import lock_filelists  # noqa: E402

SYSTEM = "x86_64-linux"
DEBUG = re.compile(r"-debug(info|source)$|-debuginfo-common-")
DEFAULT_BUILD_ARGS = ["--cores", "6", "--max-jobs", "2"]
# subpackages the /usr-files rule avoids: development files only if nothing
# else ships /usr files (header-only libraries), docs/tests only as a last resort
DOC_TEST = re.compile(r"-(tests?|testsuite|test-suite|docs?|doc-[^/]+|javadocs?|apidocs?|"
                      r"manual|examples?|demos?)$")
NOT_PREFIX = re.compile(DOC_TEST.pattern + r"|-(devel|static|headers)$")


def log(*a):
    UL.log(*a)


def lock_evr(e):
    return UL.format_evr(e["epoch"], e["version"], e["release"])


def nix_json(args):
    r = subprocess.run(["nix"] + args, stdout=subprocess.PIPE, check=True)
    return json.loads(r.stdout)


def drv_hash(drv):
    """/nix/store/<hash>-name.drv -> <hash>."""
    return os.path.basename(drv).split("-", 1)[0]


def lockgen_attr(flake, what):
    return "%s#legacyPackages.%s.nn.lockgen.%s" % (flake, SYSTEM, what)


def eval_paths(flake, names):
    """{srpm: {"drv", "out"}} for the given SRPM names (one evaluation)."""
    sel = json.dumps(sorted(names))
    apply = ("ps: builtins.listToAttrs (map (n: { name = n; value = ps.${n}; }) "
             "(builtins.fromJSON ''%s''))" % sel)
    return nix_json(["eval", "--json", lockgen_attr(flake, "paths"), "--apply", apply])


def build(paths, build_args, log_file):
    todo = sorted(p["drv"] for p in paths.values() if not os.path.exists(p["out"]))
    if not todo:
        log("subpackages: nothing to build (%d results already in the store)" % len(paths))
        return
    log("subpackages: building %d of %d queries" % (len(todo), len(paths)))
    cmd = ["nix", "build", "--keep-going", "--no-link", "--stdin"] + build_args
    out = open(log_file, "ab") if log_file else None
    try:
        r = subprocess.run(cmd, input="".join(d + "^out\n" for d in todo).encode(),
                           stdout=out, stderr=out)
    finally:
        if out:
            out.close()
    if r.returncode:
        log("subpackages: nix build exited %d (failed queries are recorded)" % r.returncode)


def stems(srpm):
    """The SRPM name with trailing version parts removed, longest first:
    python3.12 -> python3, python; postgresql16 -> postgresql."""
    out, s = [], srpm
    while True:
        t = re.sub(r"\.\d+$", "", s)
        if t == s:
            t = re.sub(r"(?<=[A-Za-z])\d+$", "", s)
        if t == s or not t:
            return out
        out.append(t)
        s = t


def choose_prefix(srpm, names, shipped_keys, summary):
    """(prefix, rule, usrFiles or None) -- design §3.1, extended: the
    eponymous subpackage, else <srpm>-libs, else the same for the SRPM name
    without its version (python3.12 -> python3, python3-libs), else the
    shipped subpackage with most /usr files that is not a test/doc/devel
    one (NOT_PREFIX; -devel/-static/-headers only if nothing else ships
    /usr files, docs/tests only if even those do not), else the first name
    (again preferring non-NOT_PREFIX names)."""
    if srpm in names:
        return srpm, "eponymous", None
    if srpm + "-libs" in names:
        return srpm + "-libs", "libs", None
    for st in stems(srpm):
        if st in names:
            return st, "stem", None
        if st + "-libs" in names:
            return st + "-libs", "stem-libs", None
    counts = {n: summary.get(shipped_keys[n], {}).get("usr", 0)
              for n in names if n in shipped_keys}
    for pool in ([n for n in names if not NOT_PREFIX.search(n)],
                 [n for n in names if not DOC_TEST.search(n)], names):
        c = [n for n in pool if counts.get(n, 0) > 0]
        if c:
            best = max(c, key=lambda n: (counts[n], -names.index(n)))
            return best, "usr-files", counts
    pool = [n for n in names if not NOT_PREFIX.search(n)] or names
    return pool[0], "first", counts or None


def derive(srpm, e, bysrpm_keys, rpms, summary):
    """Fill the repodata-derived fields (shipped, prefix, shippedMissing) of
    entry e, which has evr/names/debug/noarch/... from rpmspec."""
    shipped_keys = {rpms[k]["name"]: k for k in bysrpm_keys}
    names = e["names"]
    prefix, rule, usr = choose_prefix(srpm, names, shipped_keys, summary)
    e["shipped"] = {n: n in shipped_keys for n in names}
    e["prefix"], e["prefixRule"] = prefix, rule
    e.pop("usrFiles", None)
    if usr is not None:
        e["usrFiles"] = usr
    missing = sorted(set(shipped_keys) - set(names) - set(e.get("debug", [])))
    e.pop("shippedMissing", None)
    if missing:
        e["shippedMissing"] = missing
    return e


def entry_from_raw(raw, bysrpm_keys, rpms, summary):
    """(entry, None) or (None, failure) for one lockgen result."""
    srpm = raw["srpm"]
    errors = raw.get("errors") or {}
    # the --rpms query only feeds notBuilt: its failure alone is not fatal
    fatal = {q: e for q, e in errors.items() if q != "rpms"}
    if fatal or not raw.get("built"):
        return None, {"evr": raw["lockEvr"], "kind": "rpmspec", "errors": fatal or {
            "builtrpms": {"rc": 0, "stderr": ["rpmspec -q --builtrpms listed no package"]}}}
    if not raw.get("evrMatches"):
        return None, {"evr": raw["lockEvr"], "kind": "evr",
                      "errors": {"srpm": {"rc": 0, "stderr": [
                          "spec parses as %s, lock has %s" % (raw.get("evr"), raw["lockEvr"])]}}}
    names = [n for n, _a in raw["built"] if not DEBUG.search(n)]
    debug = [n for n, _a in raw["built"] if DEBUG.search(n)]
    if not names:
        return None, {"evr": raw["lockEvr"], "kind": "rpmspec",
                      "errors": {"builtrpms": {"rc": 0, "stderr": ["only debug packages built"]}}}
    e = {"evr": raw["lockEvr"], "names": names, "debug": debug,
         "noarch": [n for n, a in raw["built"] if a == "noarch" and not DEBUG.search(n)]}
    if raw.get("notBuilt"):
        e["notBuilt"] = raw["notBuilt"]
    if "rpms" in errors:
        e["notBuiltUnknown"] = True  # rpmspec -q --rpms failed
    for k in ("exclusiveArch", "excludeArch"):
        if raw.get(k):
            e[k] = raw[k]
    return derive(srpm, e, bysrpm_keys, rpms, summary), None


def duplicate_names(res):
    """{name: [srpms]} for subpackage names built by more than one SRPM."""
    by = {}
    for s, e in sorted(res.items()):
        for n in e["names"]:
            by.setdefault(n, []).append(s)
    return {n: ss for n, ss in sorted(by.items()) if len(ss) > 1}


def make_doc(release, srpms, res, failed, rpm_versions, summary):
    return {
        "format": 1,
        "release": release,
        "target": "x86_64",
        "rpm": sorted(rpm_versions),
        "generator": "nn.lockgen.subpackages: rpmspec -q --builtrpms --target x86_64 "
                     "--define 'distcore <dist of the locked release>' in stage0-full + *-rpm-macros "
                     "+ macros.rust-srpm",
        "coverage": {"srpms": len(srpms), "ok": len(res), "failed": len(failed),
                     "missing": len(srpms) - len(res) - len(failed)},
        "duplicateNames": duplicate_names(res),
        "filelists": lock_filelists.provenance(summary),
        "srpms": dict(sorted(res.items())),
        "failed": dict(sorted(failed.items())),
    }


def refresh(lockdir, release, rpms_doc, summary):
    """update-lock.py: after a repodata refresh, drop entries whose EVR no
    longer matches srpms.json and re-derive shipped/prefix for the rest
    (no nix needed).  Returns the number of SRPMs left to (re)query."""
    p = os.path.join(lockdir, "subpackages.json")
    with open(os.path.join(lockdir, "srpms.json")) as f:
        srpms = json.load(f)["srpms"]
    old = {"srpms": {}, "failed": {}, "rpm": []}
    if os.path.exists(p):
        with open(p) as f:
            old.update(json.load(f))
    res = {n: derive(n, e, rpms_doc["bySrpm"].get(n, []), rpms_doc["rpms"], summary)
           for n, e in old["srpms"].items()
           if n in srpms and e["evr"] == lock_evr(srpms[n])}
    failed = {n: e for n, e in old["failed"].items()
              if n in srpms and e["evr"] == lock_evr(srpms[n])}
    doc = make_doc(release, srpms, res, failed, set(old["rpm"]), summary)
    UL.write_text(p, UL.dump_one_per_line(doc))
    log("refreshed %s: %s" % (p, json.dumps(doc["coverage"], sort_keys=True)))
    return doc["coverage"]["missing"]


def selftest():
    """Prefix rule cases (design §3.1).  Returns the number of failures."""
    summary = {"a-x.x86_64": {"usr": 3}, "a-y.x86_64": {"usr": 9}}
    keys = {"a-x": "a-x.x86_64", "a-y": "a-y.x86_64"}
    cases = [
        (("a", ["a-devel", "a"], {}, {}), ("a", "eponymous")),
        (("krb5", ["krb5-devel", "krb5-libs"], {}, {}), ("krb5-libs", "libs")),
        (("a", ["a-x", "a-y", "a-z"], keys, summary), ("a-y", "usr-files")),
        (("a", ["a-z", "a-w"], {}, {}), ("a-z", "first")),
        (("a", ["a-y-devel", "a-z"], {}, {}), ("a-z", "first")),
        (("python3.12", ["python3", "python3-libs", "python3-test"], {}, {}), ("python3", "stem")),
        (("foo2.4", ["foo-libs", "foo-devel"], {}, {}), ("foo-libs", "stem-libs")),
        (("a", ["a-test", "a-x"], {"a-test": "t", "a-x": "x"}, {"t": {"usr": 99}, "x": {"usr": 2}}),
         ("a-x", "usr-files")),
        (("a", ["a-test", "a-x"], {"a-test": "t", "a-x": "x"}, {"t": {"usr": 99}}),
         ("a-test", "usr-files")),
        (("a", ["a-doc", "a-devel"], {"a-doc": "t", "a-devel": "x"}, {"t": {"usr": 99}, "x": {"usr": 2}}),
         ("a-devel", "usr-files")),
    ]
    bad = 0
    if stems("mariadb10.11") != ["mariadb10", "mariadb"] or stems("java-21-openjdk"):
        log("FAIL stems(%r)" % stems("mariadb10.11"))
        bad += 1
    for args, want in cases:
        got = choose_prefix(*args)[:2]
        if got != want:
            log("FAIL choose_prefix%r = %r, want %r" % (args[:2], got, want))
            bad += 1
    return bad


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("names", nargs="*", help="SRPM names")
    ap.add_argument("--release", default=UL.DEFAULT_RELEASE)
    ap.add_argument("--lock", default="lock", help="lock root (default ./lock)")
    ap.add_argument("--flake", default=".", help="flake reference (default .)")
    ap.add_argument("--cache-dir", default=None,
                    help="repodata cache for the filelists (default ./.cache/repodata/<rel>)")
    ap.add_argument("--seed", action="store_true", help="select nn.lockgen.seed")
    ap.add_argument("--all", action="store_true", help="select every SRPM of the lock")
    ap.add_argument("--stale", action="store_true",
                    help="select SRPMs without an entry from the current query derivation "
                         "(or another EVR, or a build failure)")
    ap.add_argument("--allow-missing-filelists", action="store_true",
                    help="warn instead of failing when the filelists do not match the lock")
    ap.add_argument("--no-build", action="store_true",
                    help="only collect results that are already in the store")
    ap.add_argument("--log", help="append nix build output to this file")
    args = ap.parse_args(argv)
    build_args = extra or DEFAULT_BUILD_ARGS

    lockdir = os.path.join(args.lock, "rocky-%s" % args.release)
    with open(os.path.join(lockdir, "srpms.json")) as f:
        srpms = json.load(f)["srpms"]
    with open(os.path.join(lockdir, "rpms.json")) as f:
        rpms_doc = json.load(f)
    out_path = os.path.join(lockdir, "subpackages.json")
    old = {"srpms": {}, "failed": {}}
    if os.path.exists(out_path):
        with open(out_path) as f:
            old = json.load(f)
    old.setdefault("srpms", {})
    old.setdefault("failed", {})

    sel = set(args.names)
    unknown = sorted(n for n in sel if n not in srpms)
    if unknown:
        log("error: not in the lock: %s" % " ".join(unknown))
        return 2
    if args.seed:
        sel.update(nix_json(["eval", "--json", lockgen_attr(args.flake, "seed")]))
    if args.all:
        sel.update(srpms)
    if args.stale:
        # every query is evaluated: an entry is stale when its derivation changed
        log("subpackages: evaluating all %d lockgen derivations (--stale)" % len(srpms))
        paths = eval_paths(args.flake, srpms)
        for n, e in srpms.items():
            cur = old["srpms"].get(n) or old["failed"].get(n)
            if (cur is None or cur["evr"] != lock_evr(e) or cur.get("kind") == "build"
                    or cur.get("lockgen") != drv_hash(paths[n]["drv"])):
                sel.add(n)
        paths = {n: paths[n] for n in sel}
    if not sel:
        log("nothing selected (names, --seed, --all or --stale): up to date")
        return 0 if args.stale else 2

    if not args.stale:
        log("subpackages: evaluating %d lockgen derivations" % len(sel))
        paths = eval_paths(args.flake, sel)
    if not args.no_build:
        build(paths, build_args, args.log)

    cache = args.cache_dir or os.path.join(".cache", "repodata", args.release)
    try:
        summary = lock_filelists.file_summary(UL, rpms_doc, cache,
                                              allow_missing=args.allow_missing_filelists)
    except lock_filelists.FilelistsError as e:
        log("error: %s (subpackages.json not written; the query results stay in the store)" % e)
        return 1
    by_srpm = rpms_doc["bySrpm"]
    rpms = rpms_doc["rpms"]

    # previous entries that still match the lock
    res, failed = {}, {}
    for n, e in old["srpms"].items():
        if n in srpms and e["evr"] == lock_evr(srpms[n]):
            res[n] = e
    for n, e in old["failed"].items():
        if n in srpms and e["evr"] == lock_evr(srpms[n]):
            failed[n] = e
    rpm_versions = set(old.get("rpm") or [])
    counts = {"ok": 0, "rpmspec": 0, "evr": 0, "build": 0, "notBuilt": 0}
    for n in sorted(sel):
        out = paths[n]["out"]
        lockgen = drv_hash(paths[n]["drv"])
        if not os.path.exists(out) and args.no_build:
            # nothing collected: the previous entry (if any) stays
            counts["notBuilt"] += 1
            continue
        res.pop(n, None)
        failed.pop(n, None)
        if not os.path.exists(out):
            failed[n] = {"evr": lock_evr(srpms[n]), "kind": "build", "lockgen": lockgen,
                         "errors": {"nix": {"rc": 1, "stderr": [
                             "nix build of %s failed (nix log %s)" % (os.path.basename(paths[n]["drv"]),
                                                                       paths[n]["drv"])]}}}
            counts["build"] += 1
            continue
        with open(out) as f:
            raw = json.load(f)
        if raw.get("rpm"):
            rpm_versions.add(raw["rpm"])
        e, fail = entry_from_raw(raw, by_srpm.get(n, []), rpms, summary)
        (e or fail)["lockgen"] = lockgen
        if e is not None:
            res[n] = e
            counts["ok"] += 1
        else:
            failed[n] = fail
            counts[fail["kind"]] += 1

    doc = make_doc(args.release, srpms, res, failed, rpm_versions, summary)
    UL.write_text(out_path, UL.dump_one_per_line(doc))
    log("subpackages: this run: %s" % json.dumps(counts, sort_keys=True))
    log("wrote %s: %s" % (out_path, json.dumps(doc["coverage"], sort_keys=True)))
    log("builddeps.json/order.json use the unshipped names: refresh them with "
        "python3 -I tools/update-lock.py --derived-only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
