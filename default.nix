# Entry point: returns the Rocky package set. See docs/DESIGN.md.
{ bootPkgs, release ? "10.2" }:
let
  readLock = file: builtins.fromJSON (builtins.readFile (./lock + "/rocky-${release}/${file}"));
  lock = readLock "srpms.json"; # SRPMs: EVR, sha256, BuildRequires (eval-time contract)
  rpmsLock = readLock "rpms.json"; # official binary RPMs (only parsed when used)
  fetch = import ./lib/sources.nix { inherit (bootPkgs) fetchurl; inherit lock rpmsLock; };

  # stage0 buildroot machinery (docs/stage0.md)
  stage0 = import ./bootstrap { pkgs = bootPkgs; inherit lock; };

  # parity/purity checks against the official RPMs (docs/parity.md)
  parity = import ./lib/parity.nix { pkgs = bootPkgs; inherit rpmsLock stage0; inherit (fetch) fetchRpm; };
in
{
  inherit lock rpmsLock stage0;
  inherit (fetch) fetchSrpm fetchRpm sources officialRpms;
  inherit (parity) mkParityCheck;
  parityChecks = parity.checks;
  parityTool = parity.tool; # store path of tools/rpm-parity.py (+ tools/parity/)
}
