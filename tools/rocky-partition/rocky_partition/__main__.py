"""rocky-partition: split rpmbuild's BUILDROOT into one Nix output per
subpackage (design docs/nix-native-design.md §2; plan schema ../PLAN.md).

  python3 -I <tool>/rocky-partition --plan plan.json        (in the build)
  python3 -I <tool>/rocky-partition --plan plan.json --replay <tree> [--remap OLD=NEW]

Exit status: 0 = done (no errors, or failOnError false), 1 = errors (see
$<prefix output>/nix-support/rocky-report.json and stderr), 2 = tool/plan
error."""
import argparse
import json
import os
import re
import sys

from . import headers
from .graph import check_graph, late, merges, nix_edges
from .integrity import Integrity
from .materialise import materialise
from .metadata import write_hidden, write_hooks, write_metadata, write_out_files
from .model import Ctx
from .plan import PlanError, load
from .refs import Refs
from .replay import remap_outputs, tree_args
from .report import Report
from .runpath import Runpath


def scrub(text, ctx):
    """the report lives in the prefix output: no other output's path (Nix
    would see an edge) and no foreign hash (an input reference)"""
    pairs = [(ctx.out[o], "$" + o) for o in ctx.out] + [(ctx.P, "$" + ctx.prefix_output)]
    for a, b in sorted(pairs, key=lambda p: -len(p[0])):
        text = text.replace(a, b)
    dirs = "|".join(re.escape(d) for d in sorted({ctx.store_dir, "/nix/store"}))
    return re.sub(r"(%s)/([0-9a-df-np-sv-z]{8})[0-9a-df-np-sv-z]{24}" % dirs, r"\1/\2...", text)


def run(a):
    plan = load(a.plan)
    rep = Report(plan.maxSamples)
    ctx = Ctx(plan, rep)
    outputs = plan.outputs
    if a.replay:
        t = tree_args(a.replay)
        plan.buildroot, plan.rpmsDir = t["buildroot"], t["rpmsDir"]
        old = t["prefix"]
        if a.remap:
            o, _, n = a.remap.partition("=")
            if o != old:
                raise PlanError("--remap %s: the tree's prefix is %s" % (a.remap, old))
            if outputs and n != outputs.get(plan.prefixOutput):
                raise PlanError("--remap target %s is not output %s (%s)" % (n, plan.prefixOutput, outputs.get(plan.prefixOutput)))
        if outputs and len(old) != len(outputs.get(plan.prefixOutput, "")):
            raise PlanError("replay: %s and %s differ in length (no same-length remap)" % (old, outputs.get(plan.prefixOutput)))
        ctx.replay_old = old
    for k in ("buildroot", "rpmsDir", "rpm"):
        if not getattr(plan, k):
            raise PlanError("plan key %s is required" % k)
    ctx.setup_outputs(outputs)
    subs = headers.read_all(plan.rpm, plan.rpmsDir, plan.rpmConfigDir)
    ctx.load_entries(subs)
    materialise(ctx, plan.buildroot, copy=plan.copy or bool(a.replay))
    ctx.integrity = Integrity(ctx)
    ctx.integrity.scan()                # FIPS integrity files (phase E must keep them valid)
    refs = Refs(ctx)
    refs.scan_all()                     # phases D, G
    Runpath(ctx, refs.elves).run()      # phase E
    refs.check_rpath_foreign()          # case 7 on the final RUNPATHs
    refs.stubs()                        # phase F
    if ctx.replay_old:
        remap_outputs(ctx)
    ctx.integrity.finish()              # recompute integrity files of changed targets
    write_metadata(ctx)                 # phase I
    write_hidden(ctx)
    write_hooks(ctx)
    edges = nix_edges(ctx)              # phase H
    succ = check_graph(ctx, edges)
    merges(ctx)
    late_doc = late(ctx, succ)
    write_out_files(ctx, late_doc)
    for o in ctx.managed:
        os.makedirs(ctx.out[o], exist_ok=True)
    header = {
        "tool": "rocky-partition", "version": 1, "srpm": plan.srpm,
        "prefixOutput": ctx.prefix_output, "replay": bool(ctx.replay_old),
        "outputs": sorted(ctx.out), "subpackages": {s: o for s, o in sorted(ctx.sub_output.items())},
        "outputRequires": {y: sorted(xs) for y, xs in sorted(ctx.out_requires.items())},
    }
    text = scrub(json.dumps(rep.to_json(header), indent=1, default=sorted) + "\n", ctx)
    dest = os.path.join(ctx.out[ctx.prefix_output], "nix-support", "rocky-report.json")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    for p in filter(None, [dest, plan.reportFile, a.report]):
        with open(p, "w") as f:
            f.write(text)
    s = rep.summary()
    print("rocky-partition: %s: %d outputs, %d subpackages, %d errors, %d warnings%s" % (
        plan.srpm or "?", len(ctx.out), len(ctx.sub_output), s["errors"], s["warnings"],
        "" if not s["errors"] else " (%s)" % ", ".join("%s %d" % kv for kv in sorted(s["byCode"]["error"].items()))),
        file=sys.stderr)
    return 1 if s["errors"] and plan.failOnError and not a.no_fail else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rocky-partition", description=__doc__.split("\n\n")[0])
    ap.add_argument("--plan", required=True, help="plan.json, or the __structuredAttrs attrs file with rockyPlan")
    ap.add_argument("--replay", metavar="TREE", help="kept build tree (BUILDROOT, RPMS, prefix); development only")
    ap.add_argument("--remap", metavar="OLD=NEW", help="with --replay: the tree's prefix and the new prefix output path")
    ap.add_argument("--report", help="also write the report here")
    ap.add_argument("--no-fail", action="store_true", help="exit 0 even with errors (experiments)")
    a = ap.parse_args(argv)
    try:
        return run(a)
    except (PlanError, headers.HeaderError) as e:
        print("rocky-partition: error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
