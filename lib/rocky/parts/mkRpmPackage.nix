# nn.mkRpmPackage stage { srpm, overrides ? ... }: one multi-output derivation
# per SRPM (lib/rocky/mk-rpm-package.nix, design §11.1).
{ bootPkgs, lib, lock, self, ... }:
import ../mk-rpm-package.nix {
  inherit lib lock;
  names = self.names;
  overridesLib = self.overrides;
  unions = self.unions;
  partitionTool = self.partitionTool;
  srpmLib = import ../../srpm.nix { pkgs = bootPkgs; inherit lock; };
}
