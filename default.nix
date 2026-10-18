# Entry point: returns the Rocky package set. See docs/DESIGN.md.
{ bootPkgs
, release ? "10.2"
, kernelHeadersRpm ? null # Rocky kernel-headers RPM for the glibc buildroot (packages/glibc.nix)
}:
let
  readLock = file: builtins.fromJSON (builtins.readFile (./lock + "/rocky-${release}/${file}"));
  lock = readLock "srpms.json"; # SRPMs: EVR, sha256, BuildRequires (eval-time contract)
  rpmsLock = readLock "rpms.json"; # official binary RPMs (only parsed when used)
  fetch = import ./lib/sources.nix { inherit (bootPkgs) fetchurl; inherit lock rpmsLock; };

  # stage0 buildroot machinery (docs/stage0.md)
  stage0 = import ./bootstrap { pkgs = bootPkgs; inherit lock; inherit (fetch) officialRpms; };

  # milestone 1: the glibc SRPM rebuilt in stage0 (docs/glibc.md)
  glibc = import ./packages/glibc.nix {
    pkgs = bootPkgs;
    inherit stage0 rpmsLock kernelHeadersRpm;
    inherit (fetch) officialRpms;
  };
in
{
  inherit lock rpmsLock;
  inherit (fetch) fetchSrpm fetchRpm sources officialRpms;
  inherit stage0;

  # rpmbuild results by SRPM name ($out/RPMS, $out/SRPMS, $out/logs)
  srpm = { glibc = glibc.build; };
  # binary RPM name -> its payload as an FHS tree (rpmTree, allowedReferences = [ ])
  rpms = glibc.rpms;
  # per-SRPM extras: buildroot, `trees` (all rpms.* in one linkFarm), `sanity`
  packageSets = { inherit glibc; };
}
