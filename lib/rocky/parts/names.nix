# nn.names: output/store names (lib/rocky/names.nix) plus the static
# subpackage lists they are computed from (§3.2).
#
#   subpackages          lock/rocky-<rel>/subpackages.json (rpmspec -q, written by
#                        the lock generator), { } while it does not exist
#   subpackagesFor srpm  that entry; else a fixture lib/rocky/tests/<srpm>-subpackages.json;
#                        else derived from rpms.json bySrpm (shipped subpackages only,
#                        prefix by defaultPrefix, fromRpms = true)
#   outputsForSrpm { srpm, mergeOutputs ? [ ], prefixSubpackage ? null }
#                        outputsFor over subpackagesFor srpm
{ lib, rpmsLock, readLock, release, repo, ... }:
let
  names = import ../names.nix { inherit lib; };

  lockFile = repo + "/lock/rocky-${release}/subpackages.json";
  # accept { <srpm> = {...}; } and a wrapped { subpackages = { <srpm> = {...}; }; ... }
  subpackages =
    if builtins.pathExists lockFile then
      let j = readLock "subpackages.json"; in j.subpackages or j.bySrpm or j
    else { };

  fixture = srpm: ../tests + "/${srpm}-subpackages.json";

  fromRpms = srpm:
    let ns = lib.unique (map (k: rpmsLock.rpms.${k}.name) (rpmsLock.bySrpm.${srpm} or [ ]));
    in {
      names = ns;
      prefix = names.defaultPrefix srpm ns;
      shipped = lib.genAttrs ns (_: true);
      fromRpms = true;
    };

  subpackagesFor = srpm:
    if subpackages ? ${srpm} then subpackages.${srpm}
    else if builtins.pathExists (fixture srpm) then lib.importJSON (fixture srpm)
    else fromRpms srpm;
in
names // {
  inherit subpackages subpackagesFor fromRpms;
  outputsForSrpm = { srpm, mergeOutputs ? [ ], prefixSubpackage ? null }:
    names.outputsFor { inherit srpm mergeOutputs prefixSubpackage; sub = subpackagesFor srpm; };
}
