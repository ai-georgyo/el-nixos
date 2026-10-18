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

      # `nix run .#<tool> -- args`; run from the repository root (the tools
      # read/write ./lock). The whole tools/ dir is copied so scripts can load
      # their siblings.
      pyApp = script: description: {
        type = "app";
        program = "${bootPkgs.writeShellScript script ''
          exec ${bootPkgs.python3}/bin/python3 -I ${./tools}/${script}.py "$@"
        ''}";
        meta = { inherit description; };
      };
    in
    {
      legacyPackages.${system} = rocky;
      packages.${system} = { };
      # stage0 acceptance tests (docs/stage0.md) + RPM parity checks (docs/parity.md)
      checks.${system} = rocky.stage0.tests // rocky.parityChecks;

      apps.${system} = {
        update-lock = pyApp "update-lock" "Regenerate lock/rocky-<rel>/ from Rocky repodata";
        resolve-buildrequires = pyApp "resolve-buildrequires" "Resolve an SRPM's BuildRequires to a mock-like buildroot closure";
        rpm-parity = {
          type = "app";
          program = "${bootPkgs.writeShellScript "rpm-parity" ''
            PATH=${bootPkgs.zstd}/bin:$PATH exec ${bootPkgs.python3}/bin/python3 -I ${rocky.parityTool} "$@"
          ''}";
          meta.description = "Compare RPMs against the official Rocky RPMs (docs/parity.md)";
        };
      };
    };
}
