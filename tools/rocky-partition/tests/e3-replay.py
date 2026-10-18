#!/usr/bin/env python3
"""Experiment E3 driver: replay a kept relocated tree (trees.nix e3.*) into
fake same-length outputs and print the partition summary.

  e3-replay.py --tool TOOLDIR --rpm RPMPREFIX --patchelf PATCHELF --work DIR
               [--overrides e3-overrides.json] [--run NAME] TREE SRPM

TREE is the tree's buildtree dir. The subpackage -> output map follows the
design's §2.12 naming rule (prefix subpackage -> out, <srpm>-devel -> dev,
<srpm>-libs -> lib, <srpm>-X -> X, [^A-Za-z0-9_] -> _), after mergeOutputs.
The prefix subpackage is the eponymous one, else <srpm>-libs (§3.1), or
"_prefixSub" of the overrides. The overrides file maps SRPM -> extra plan
keys (`--run NAME` picks "SRPM:NAME" instead). Outputs live in a fake store
dir /tmp/e3-st -> WORK/store (the same code path as checks.nn-partition-replay, minus
Nix's own output check); the report is WORK/<run>/report.json.
Exit status: the partitioner's (with --no-fail: 0 unless the plan is bad)."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", required=True)
    ap.add_argument("--rpm", required=True, help="stage0 rpm prefix (usr/bin/rpm, usr/lib/rpm)")
    ap.add_argument("--patchelf", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--overrides")
    ap.add_argument("--run", default="")
    ap.add_argument("tree")
    ap.add_argument("srpm")
    a = ap.parse_args()
    key = a.srpm + (":" + a.run if a.run else "")
    extra = {}
    if a.overrides:
        with open(a.overrides) as f:
            extra = dict(json.load(f).get(key, {}))
    with open(os.path.join(a.tree, "prefix")) as f:
        prefix = f.read().strip()
    name = os.path.basename(prefix)[33:]
    rpm, cfg = os.path.join(a.rpm, "usr/bin/rpm"), os.path.join(a.rpm, "usr/lib/rpm")
    names = []
    for d, _dirs, files in os.walk(os.path.join(a.tree, "RPMS")):
        for f in files:
            n = subprocess.run([rpm, "-qp", "--nosignature", "--nodigest", "--qf", "%{NAME}", os.path.join(d, f)],
                               env=dict(os.environ, RPM_CONFIGDIR=cfg), capture_output=True, text=True,
                               check=True).stdout
            if not n.endswith(("-debuginfo", "-debugsource")):
                names.append(n)
    names.sort()
    psub = extra.pop("_prefixSub", a.srpm if a.srpm in names else a.srpm + "-libs")
    merges = extra.get("mergeOutputs", [])
    special = {a.srpm + "-devel": "dev", a.srpm + "-libs": "lib", psub: "out"}

    def oname(n):
        n = next((g[0] for g in merges if n in g), n)
        if n in special:
            return special[n]
        return re.sub(r"[^A-Za-z0-9_]", "_", n[len(a.srpm) + 1:] if n.startswith(a.srpm + "-") else n)

    run = key.replace(":", "-")
    work = os.path.abspath(os.path.join(a.work, run))
    # the fake store dir must be as long as /nix/store (same-length remap):
    # /tmp/e3-st, a symlink to WORK/store (the data stays out of /tmp)
    store, real = "/tmp/e3-st", os.path.join(os.path.abspath(a.work), "store")
    os.makedirs(real, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    if not os.path.lexists(store):
        os.symlink(real, store)
    elif os.path.realpath(store) != os.path.realpath(real):
        sys.exit("e3-replay: %s points elsewhere (%s)" % (store, os.path.realpath(store)))
    subs = {n: oname(n) for n in names}

    def fake(o):
        h = "".join(NIX32[b % 32] for b in hashlib.sha256((run + "/" + o).encode()).digest()[:32])
        return "%s/%s-%s%s" % (store, h, name, "" if o == "out" else "-" + o)
    outputs = {o: fake(o) for o in sorted(set(subs.values()) | {"debug"})}
    if len(outputs["out"]) != len(prefix):
        sys.exit("e3-replay: %s and %s differ in length" % (outputs["out"], prefix))
    for p in outputs.values():
        if os.path.lexists(p):
            subprocess.run(["chmod", "-R", "u+w", p], check=True)
            shutil.rmtree(p)
    plan = {"srpm": a.srpm, "rpm": rpm, "rpmConfigDir": cfg, "outputs": outputs, "subpackages": subs,
            "patchelf": a.patchelf, "storeDir": store}
    plan.update(extra)
    pf = os.path.join(work, "plan.json")
    with open(pf, "w") as f:
        json.dump(plan, f, indent=1)
    rf = os.path.join(work, "report.json")
    rc = subprocess.run([sys.executable, "-I", os.path.join(a.tool, "rocky-partition"), "--plan", pf,
                         "--replay", a.tree, "--report", rf, "--no-fail"]).returncode
    print("e3-replay: %s: %d outputs, report %s" % (key, len(outputs), rf))
    return rc


if __name__ == "__main__":
    sys.exit(main())
