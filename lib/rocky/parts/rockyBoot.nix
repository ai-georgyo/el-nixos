# nn.rockyBoot.<stage>: the relocated packages of each bootstrap stage
# (default.nix exposes it as legacyPackages.x86_64-linux.rockyBoot, the flake's
# hydraJobs as nixNative without the `rpm` aliases):
#   rockyBoot.<stage>.<srpm>        the package (multi-output derivation;
#                                   lateBind.wrap result where the stage binds)
#   rockyBoot.<stage>.rpm.<rpm>     the output holding that shipped RPM
#                                   (rockyBoot.s1.rpm."glibc-devel" = glibc.dev,
#                                   design §2.12; merged names alias the
#                                   representative, unshipped subpackages have
#                                   no alias but are outputs of the package)
# The stage objects (resolveBuildDeps, glibcBuildDeps, libgccForGlibc, the
# toolchains, ...) are nn.stages.<stage>.
# `rpm` is reserved for the aliases: the rpm SRPM itself, once a stage builds
# it, is rockyBoot.<stage>.rpm.rpm (its prefix subpackage, i.e. its `out`).
{ lib, self, ... }:
let
  withAliases = stage:
    assert lib.assertMsg (!(stage.pkgs ? rpm))
      "rockyBoot.${stage.name}: a package attribute named `rpm` would shadow the RPM-name aliases; reach the rpm SRPM as rockyBoot.${stage.name}.rpm.rpm";
    stage.pkgs // { rpm = stage.rpm; };
in
{
  s1 = withAliases self.stages.s1;
}
