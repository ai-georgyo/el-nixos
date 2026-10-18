{
  description = "Rocky Linux built from source RPMs with Nix";

  inputs = {
    # Used ONLY to bootstrap (stage0). Nothing we ship may reference it.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      bootPkgs = nixpkgs.legacyPackages.${system};
      rocky = import ./default.nix { inherit bootPkgs; };
    in
    {
      legacyPackages.${system} = rocky;
      packages.${system} = { };
      # stage0 acceptance tests (docs/stage0.md)
      checks.${system} = rocky.stage0.tests;
    };
}
