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
      packages.${system} = {
        glibc = rocky.rpms.glibc;                        # payload tree of the main glibc RPM (allowedReferences = [ ])
        glibc-rpms = rocky.srpm.glibc;                   # rpmbuild result: RPMS/{x86_64,noarch}, SRPMS/, logs/
        kernel-headers = rocky.stage0.rpms.kernel-headers;  # payload tree of Rocky's kernel-headers RPM
        kernel-headers-rpms = rocky.stage0.kernelHeadersBuild; # rpmbuild result of the kernel SRPM (headers only)
      };
      # stage0 acceptance tests (docs/stage0.md), RPM parity checks
      # (docs/parity.md; includes glibc-parity, kernel-headers-parity) and the
      # glibc checks (docs/glibc.md)
      checks.${system} = rocky.stage0.tests // rocky.parityChecks // {
        glibc-purity = rocky.packageSets.glibc.trees;  # all 224 subpackage trees, allowedReferences = [ ]
        glibc-sanity = rocky.packageSets.glibc.sanity; # NEVRs, configure results, ELF checks
      };

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
