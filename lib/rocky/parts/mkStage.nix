# nn.mkStage { name, stdenv, ccFor, libcFor, ..., packages }: a bootstrap stage
# as a lazy fixpoint (lib/rocky/stage.nix, design §11.2).  mkRpmPackage,
# purity and overridesFor are filled in here.
{ lib, readLock, self, ... }:
args: import ../stage.nix { inherit lib readLock; names = self.names; } ({
  inherit (self) mkRpmPackage purity;
  overridesFor = self.overrides.overridesFor;
} // args)
