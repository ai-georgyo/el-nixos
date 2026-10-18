# checks.nn-order: lock/rocky-<rel>/order.json is consistent with
# builddeps.json and srpms.json, the build graph minus the back edges is
# acyclic, every back edge's target is in bootTargets and every SRPM with a
# library back edge is in secondPass; sccs, bootTargets, secondPass,
# selfLoops, stats and the per-SRPM scc ids equal what needs/back imply
# (nothing missing, nothing extra) (tools/lock_order.py --check; design
# §8.3).  Pure data check: no package is built.
{ bootPkgs, lib, release, repo, ... }:
let
  lockDir = repo + "/lock/rocky-${release}";
  src = lib.fileset.toSource {
    root = repo;
    fileset = lib.fileset.unions [
      (lockDir + "/srpms.json")
      (lockDir + "/builddeps.json")
      (lockDir + "/order.json")
      (repo + "/tools/lock_order.py")
    ];
  };
in
{
  nn-order = bootPkgs.runCommand "nn-order-check" { nativeBuildInputs = [ bootPkgs.python3 ]; } ''
    python3 -I ${src}/tools/lock_order.py --check ${src}/lock/rocky-${release} > report.txt \
      || { cat report.txt; exit 1; }
    cat report.txt
    cp report.txt $out
  '';
}
