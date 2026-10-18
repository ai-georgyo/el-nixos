# Entry point: returns the Rocky package set. See docs/DESIGN.md.
{ bootPkgs, release ? "10.2" }:
let
  readLock = file: builtins.fromJSON (builtins.readFile (./lock + "/rocky-${release}/${file}"));
  lock = readLock "srpms.json"; # SRPMs: EVR, sha256, BuildRequires (eval-time contract)
  rpmsLock = readLock "rpms.json"; # official binary RPMs (only parsed when used)
  fetch = import ./lib/sources.nix { inherit (bootPkgs) fetchurl; inherit lock rpmsLock; };
in
{
  inherit lock rpmsLock;
  inherit (fetch) fetchSrpm fetchRpm sources officialRpms;
}
