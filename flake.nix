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
        glibc-rpms = rocky.srpm.glibc;                   # rpmbuild result: RPMS/{x86_64,noarch}, SRPMS/ (^logs: build.log, ...)
        kernel-headers = rocky.stage0.rpms.kernel-headers;  # payload tree of Rocky's kernel-headers RPM
        kernel-headers-rpms = rocky.stage0.kernelHeadersBuild; # rpmbuild result of the kernel SRPM (headers only)
      };
      # stage0 acceptance tests (docs/stage0.md), RPM parity checks
      # (docs/parity.md; includes glibc-parity, kernel-headers-parity) and the
      # glibc checks (docs/glibc.md)
      checks.${system} = rocky.stage0.tests // rocky.parityChecks // {
        glibc-purity = rocky.packageSets.glibc.trees;  # all 224 subpackage trees, allowedReferences = [ ]
        glibc-sanity = rocky.packageSets.glibc.sanity; # NEVRs, configure results, ELF checks
        glibc-abi = rocky.packageSets.glibc.abi;       # binutils: dynsyms/versions, archive symbols, headers vs official
        glibc-runtime = rocky.packageSets.glibc.runtime; # RPM-only roots without /nix/store: same behaviour as official
      } // rocky.nn.checks;                            # nix-native checks (nn-*, lib/rocky/checks)

      # Every job for CI / tools/build-jobs.sh (nix-eval-jobs): the packages,
      # the checks, and the per-SRPM results (rpmbuild outputs and payload
      # trees, including stage0's).  Nested attrsets; build-jobs.sh passes
      # --force-recurse.
      hydraJobs = {
        packages.${system} = self.packages.${system};
        checks.${system} = self.checks.${system};
        # relocated packages per bootstrap stage (rockyBoot.<stage>.<srpm>; the
        # rpm.<name> aliases name the same derivations' outputs and are left
        # out; <srpm>-bound = the bind derivation of a late-bound package,
        # whose own drvPath is the raw build: lib/rocky/parts/nixNative.nix)
        nixNative.${system} = rocky.nn.nixNative.jobs;
        srpm.${system} = rocky.srpm;                 # rpmbuild results (out + logs)
        rpms.${system} = rocky.rpms;                 # payload trees of every glibc subpackage
        stage0.${system} = {
          inherit (rocky.stage0) binutils gcc glibc rpm debugedit texinfo71 glibcBuildDeps
            buildroot buildrootRelease buildrootFull buildrootFullKernelHeaders;
          inherit (rocky.stage0.rpmLibs) zstd file elfutils;
          srpm = rocky.stage0.srpm;                  # rocky-release, which, kernel(-headers), macro packages
          rpms = rocky.stage0.rpms;
        };
      };

      apps.${system} = {
        update-lock = pyApp "update-lock" "Regenerate lock/rocky-<rel>/ from Rocky repodata";
        # needs nix on PATH; refreshes lock/rocky-<rel>/subpackages.json (rpmspec -q
        # per SRPM, nn.lockgen); then run update-lock --derived-only
        lock-subpackages = pyApp "lock_subpackages" "Regenerate lock/rocky-<rel>/subpackages.json (rpmspec -q of every SRPM via nn.lockgen)";
        resolve-buildrequires = pyApp "resolve-buildrequires" "Resolve an SRPM's BuildRequires to a mock-like buildroot closure";
        # nix-eval-jobs over hydraJobs, build what is neither built nor cached
        build-jobs = {
          type = "app";
          program = "${bootPkgs.writeShellScript "build-jobs" ''
            PATH=${bootPkgs.nix-eval-jobs}/bin:${bootPkgs.jq}/bin:$PATH exec ${bootPkgs.bash}/bin/bash ${./tools/build-jobs.sh} "$@"
          ''}";
          meta.description = "Evaluate hydraJobs with nix-eval-jobs (no IFD) and build every job not yet built or cached";
        };
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
