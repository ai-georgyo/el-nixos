# nn.overrides: schema, validation and loader of packages/<srpm>/default.nix
# (lib/rocky/overrides.nix, §8.1; fields documented in packages/README-overrides.md).
{ lib, repo, self, ... }:
import ../overrides.nix {
  inherit lib;
  packagesDir = repo + "/packages";
  unions = self.unions;
}
