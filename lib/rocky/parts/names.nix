# nn.names: output/store names (lib/rocky/names.nix) plus the static
# subpackage lists they are computed from (§3.2).
#
#   subpackagesDoc       lock/rocky-<rel>/subpackages.json as written by
#                        tools/lock_subpackages.py ({ format = 1; srpms; failed;
#                        coverage; ... }), null while it does not exist
#   subpackages          its `srpms` ({ <srpm> = entry; }), { } without the file
#                        (a bare { <srpm> = entry; } file is accepted too)
#   subpackagesFor srpm  the lock entry; else the fixture lib/rocky/tests/<srpm>-subpackages.json;
#                        else an eval error (naming the lock file, its coverage and
#                        the command that fills it).  Never a silent guess: an entry
#                        derived from rpms.json lacks the unshipped subpackages, so
#                        the build would fail with "built but not declared" (§3.2)
#   subpackagesOrRpms srpm  the same, but fromRpms instead of the error (exploration,
#                        lock-wide sweeps; marked fromRpms = true)
#   fromRpms srpm        derived from rpms.json bySrpm: shipped subpackages only,
#                        prefix by defaultPrefix (null without eponymous/-libs)
#   outputsForSrpm { srpm, mergeOutputs ? [ ], prefixSubpackage ? null }
#                        outputsFor over subpackagesFor srpm
{ lib, rpmsLock, readLock, release, repo, ... }:
let
  names = import ../names.nix { inherit lib; };

  lockRel = "lock/rocky-${release}/subpackages.json";
  hasLockFile = builtins.pathExists (repo + "/${lockRel}");

  subpackagesDoc = if hasLockFile then readLock "subpackages.json" else null;

  subpackages =
    if subpackagesDoc == null then { }
    else if subpackagesDoc ? format then
      if subpackagesDoc.format == 1 && subpackagesDoc ? srpms then subpackagesDoc.srpms
      else throw "${lockRel}: unknown format ${builtins.toJSON subpackagesDoc.format} (nn.names reads format 1 with `srpms`)"
    else subpackagesDoc;

  fixture = srpm: ../tests + "/${srpm}-subpackages.json";

  fromRpms = srpm:
    let ns = lib.unique (map (k: rpmsLock.rpms.${k}.name) (rpmsLock.bySrpm.${srpm} or [ ]));
    in {
      names = ns;
      prefix = names.defaultPrefix srpm ns;
      shipped = lib.genAttrs ns (_: true);
      fromRpms = true;
    };

  missing = srpm:
    let
      failed = (subpackagesDoc.failed or { }).${srpm} or null;
      cov = subpackagesDoc.coverage or null;
    in
    throw ("nn.names: no subpackage list for ${srpm}: "
      + (if !hasLockFile then "${lockRel} does not exist"
         else if failed != null then "${lockRel} records a failed query (${failed.kind or "?"}): ${builtins.toJSON (failed.errors or { })}"
         else "${lockRel} has no entry"
           + lib.optionalString (cov != null) " (coverage: ${builtins.toJSON cov})")
      + "; run `python3 -I tools/lock_subpackages.py ${srpm}`");

  lookup = orElse: srpm:
    if subpackages ? ${srpm} then subpackages.${srpm}
    else if builtins.pathExists (fixture srpm) then lib.importJSON (fixture srpm)
    else orElse srpm;

  subpackagesFor = lookup missing;
in
names // {
  inherit subpackagesDoc subpackages subpackagesFor fromRpms;
  subpackagesOrRpms = lookup fromRpms;
  outputsForSrpm = { srpm, mergeOutputs ? [ ], prefixSubpackage ? null }:
    names.outputsFor { inherit srpm mergeOutputs prefixSubpackage; sub = subpackagesFor srpm; };
}
