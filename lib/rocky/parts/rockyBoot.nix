# nn.rockyBoot.<stage>.<srpm>: the relocated packages of each bootstrap stage
# (default.nix exposes it as legacyPackages.x86_64-linux.rockyBoot, hydraJobs
# as nixNative).  Only derivations here (nix-eval-jobs recurses into it); the
# stage objects (rpm.<name> aliases, resolveBuildDeps, glibcBuildDeps, ...)
# are nn.stages.<stage>.
{ self, ... }:
{
  s1 = self.stages.s1.pkgs;
}
