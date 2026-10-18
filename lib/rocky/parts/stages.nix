# nn.stages.<stage>: the bootstrap stage objects (lib/rocky/stage.nix fixpoints).
#   s1          bootstrap/nn/s1.nix: every S1 package on the stage0 libc
#   s1Glibc1    the same with glibc1 = true: S1 packages after glibc¹ link
#               rockyBoot.s1.glibc (the design's order; switched on once M1 holds)
# rockyBoot.<stage> (lib/rocky/parts/rockyBoot.nix) is each stage's `pkgs`.
{ bootPkgs, lib, lock, stage0, fetch, self, ... }:
let
  s1 = glibc1: import ../../../bootstrap/nn/s1.nix {
    inherit bootPkgs lib lock stage0 fetch glibc1;
    nn = self;
    mkStage = self.mkStage;
  };
in
{
  s1 = s1 false;
  s1Glibc1 = s1 true;
}
