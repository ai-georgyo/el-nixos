"""Turn the raw output of rpmspec-query.sh into one JSON document.

    python3 -I raw2json.py OUTDIR SRPM LOCK-EVR DIST > result.json

Fields (consumed by tools/lock_subpackages.py):
  srpm, lockEvr, dist, spec    inputs, for provenance
  rpm                          `rpm --version` of the buildroot
  evr                          [E:]V-R of the parsed spec (source header)
  evrMatches                   evr == lockEvr
  exclusiveArch, excludeArch   source header arch restrictions
  built                        [[name, arch], ...] in spec order (rpmspec -q
                               --builtrpms), debuginfo/debugsource included
  notBuilt                     declared %package names without %files
  ok                           every query exited 0 and `built` is non-empty
  errors                       {query: last stderr lines} for failed queries
  stdoutNoise                  number of non-result stdout lines (macros that print)
Store paths in messages are normalised (the result must not reference them).
"""
import json
import os
import re
import sys

STORE = re.compile(r"/nix/store/[a-z0-9]{32}-")


def read(d, n, default=""):
    try:
        with open(os.path.join(d, n), encoding="utf-8", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return default


MARK = "LOCKGEN\t"


def rows(text):
    """Result rows (lines carrying the LOCKGEN marker), split at tabs."""
    return [line[len(MARK):].split("\t") for line in text.splitlines() if line.startswith(MARK)]


def noise(text):
    return sum(1 for line in text.splitlines() if line.strip() and not line.startswith(MARK))


def strip_epoch(evr):
    return evr[2:] if evr.startswith("0:") else evr


def main():
    d, srpm, lock_evr, dist = sys.argv[1:5]
    doc = {"srpm": srpm, "lockEvr": lock_evr, "dist": dist,
           "spec": read(d, "spec").strip() or None, "errors": {},
           "rpm": read(d, "rpm-version").strip() or None}
    rc = {}
    for q in ("srpm", "builtrpms", "rpms"):
        r = read(d, q + ".rc").strip()
        rc[q] = int(r) if r else None
        if rc[q] != 0:
            err = STORE.sub("/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-", read(d, q + ".err"))
            lines = [x for x in err.splitlines() if x.strip()]
            doc["errors"][q] = {"rc": rc[q], "stderr": lines[-25:]}
    src = rows(read(d, "srpm.tsv"))
    if src:
        f = src[0] + ["", "", "", ""]
        doc["evr"] = strip_epoch(f[1])
        doc["exclusiveArch"] = f[2].split()
        doc["excludeArch"] = f[3].split()
    else:
        doc["evr"] = None
    doc["evrMatches"] = doc["evr"] == lock_evr
    built, seen = [], set()
    for r in rows(read(d, "builtrpms.tsv")):
        if len(r) >= 2 and r[0] not in seen:
            seen.add(r[0])
            built.append([r[0], r[1]])
    doc["built"] = built
    declared = []
    for r in rows(read(d, "rpms.tsv")):
        if r and r[0] not in seen and r[0] not in declared:
            declared.append(r[0])
    doc["notBuilt"] = declared
    doc["stdoutNoise"] = sum(noise(read(d, q + ".tsv")) for q in ("srpm", "builtrpms", "rpms"))
    doc["ok"] = all(v == 0 for v in rc.values()) and bool(built)
    json.dump(doc, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
