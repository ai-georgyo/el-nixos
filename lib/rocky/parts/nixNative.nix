# nn.nixNative: the CI jobs of the relocated packages (the flake's
# hydraJobs.nixNative.<system>, built by tools/build-jobs.sh through
# nix-eval-jobs, which builds each job's drvPath):
#   jobsFor pkgs   a stage's package set (rockyBoot.<stage>) -> its jobs:
#                  every package, without the `rpm` alias set (the same
#                  derivations' outputs), plus `<srpm>-bound` = pkg.bound for
#                  each lateBind.wrap result.  A bound package's top-level
#                  drvPath (and `nix build <pkg>^*`) is the RAW build: the
#                  bound outputs that consumers and profiles reference come
#                  from the bind derivation, which no other job names (M1
#                  review)
#   jobs.<stage>   jobsFor rockyBoot.<stage>
{ lib, self, ... }:
let
  jobsFor = pkgs:
    let
      ps = removeAttrs pkgs [ "rpm" ];
      bound = lib.concatMapAttrs (n: p:
        lib.optionalAttrs (builtins.isAttrs p && p ? lateBound && p ? bound) { "${n}-bound" = p.bound; }) ps;
      clash = lib.attrNames (builtins.intersectAttrs bound ps);
    in
    assert lib.assertMsg (clash == [ ])
      "nn.nixNative.jobsFor: package names ${toString clash} clash with the bind jobs <srpm>-bound";
    ps // bound;
in
{
  inherit jobsFor;
  jobs = lib.mapAttrs (_: jobsFor) self.rockyBoot;
}
