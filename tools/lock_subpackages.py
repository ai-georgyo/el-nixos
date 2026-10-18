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
   them at that EVR).

Per SRPM (one line each, sorted keys):

    "<srpm>": {"evr": "<[E:]V-R>",
               "names": [...],          # spec order, rpmspec -q --builtrpms, debug packages excluded
               "debug": [...],          # -debuginfo/-debugsource/-debuginfo-common-* names
               "noarch": [...],         # names built as noarch (the rest: x86_64)
               "shipped": {"<name>": true|false},   # in rpms.json bySrpm
               "prefix": "<name>",      # the subpackage compiled with %_prefix = $out
               "prefixRule": "eponymous" | "libs" | "usr-files" | "first",
               "usrFiles": {...},       # prefixRule usr-files: /usr file counts of the shipped names
               "notBuilt": [...],       # declared %package without %files (if any;
                                        # "notBuiltUnknown": true if that query failed)
               "shippedMissing": [...], # shipped from this SRPM but not built by the spec (if any)
               "exclusiveArch": [...], "excludeArch": [...]}   # (if any)

Prefix rule: the eponymous subpackage, else ``<srpm>-libs``, else the
shipped subpackage owning most /usr files in the official filelists (ties:
spec order), else the first name.  Failures go to ``"failed": {"<srpm>":
{"evr", "kind": "rpmspec"|"build"|"evr", "errors"}}`` instead of aborting.
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


def log(*a):
    UL.log(*a)


def lock_evr(e):
    return UL.format_evr(e["epoch"], e["version"], e["release"])


def nix_json(args):
    r = subprocess.run(["nix"] + args, stdout=subprocess.PIPE, check=True)
    return json.loads(r.stdout)


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


def choose_prefix(srpm, names, shipped_keys, summary):
    """(prefix, rule, usrFiles or None) -- design §3.1."""
    if srpm in names:
        return srpm, "eponymous", None
    if srpm + "-libs" in names:
        return srpm + "-libs", "libs", None
    counts = {n: summary.get(shipped_keys[n], {}).get("usr", 0)
              for n in names if n in shipped_keys}
    if counts and max(counts.values()) > 0:
        best = max(names, key=lambda n: (counts.get(n, -1), -names.index(n)))
        return best, "usr-files", counts
    return names[0], "first", counts or None


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


def make_doc(release, srpms, res, failed, rpm_versions):
    return {
        "format": 1,
        "release": release,
        "target": "x86_64",
        "rpm": sorted(rpm_versions),
        "generator": "nn.lockgen.subpackages: rpmspec -q --builtrpms --target x86_64 "
                     "--define 'dist <dist of the locked release>' in stage0-full + *-rpm-macros",
        "coverage": {"srpms": len(srpms), "ok": len(res), "failed": len(failed),
                     "missing": len(srpms) - len(res) - len(failed)},
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
    doc = make_doc(release, srpms, res, failed, set(old["rpm"]))
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
    ]
    bad = 0
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
                    help="select SRPMs without an up-to-date entry (and build failures)")
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
        for n, e in srpms.items():
            cur = old["srpms"].get(n) or old["failed"].get(n)
            if cur is None or cur["evr"] != lock_evr(e) or cur.get("kind") == "build":
                sel.add(n)
    if not sel:
        log("nothing selected (names, --seed, --all or --stale)")
        return 2

    log("subpackages: evaluating %d lockgen derivations" % len(sel))
    paths = eval_paths(args.flake, sel)
    if not args.no_build:
        build(paths, build_args, args.log)

    cache = args.cache_dir or os.path.join(".cache", "repodata", args.release)
    summary = lock_filelists.file_summary(UL, rpms_doc, cache)
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
        res.pop(n, None)
        failed.pop(n, None)
        out = paths[n]["out"]
        if not os.path.exists(out):
            if args.no_build:
                counts["notBuilt"] += 1
                continue
            failed[n] = {"evr": lock_evr(srpms[n]), "kind": "build",
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
        if e is not None:
            res[n] = e
            counts["ok"] += 1
        else:
            failed[n] = fail
            counts[fail["kind"]] += 1

    doc = make_doc(args.release, srpms, res, failed, rpm_versions)
    UL.write_text(out_path, UL.dump_one_per_line(doc))
    log("subpackages: this run: %s" % json.dumps(counts, sort_keys=True))
    log("wrote %s: %s" % (out_path, json.dumps(doc["coverage"], sort_keys=True)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
