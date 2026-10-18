# Fetchers + attrsets over the lockfiles:
#   sources.<srpm name>            fetched SRPM (FOD), e.g. sources.glibc
#   officialRpms.<name>            official binary RPM (FOD), e.g. officialRpms.glibc
#   officialRpms."<name>.<arch>"   same, addressed by name.arch
# rpms.json is only parsed when officialRpms / fetchRpm is used.
{ fetchurl, lock, rpmsLock }:
let
  fetchSrpm = import ./fetch-srpm.nix { inherit fetchurl lock; };
  fetchRpm = import ./fetch-rpm.nix { inherit fetchurl rpmsLock; };
  byKey = builtins.mapAttrs (key: _: fetchRpm key) rpmsLock.rpms;
  # name -> drv; x86_64 wins over noarch should a name ever exist for both
  # (listToAttrs keeps the first occurrence).
  keys = builtins.attrNames rpmsLock.rpms;
  withArch = arch: builtins.filter (k: rpmsLock.rpms.${k}.arch == arch) keys;
  byName = builtins.listToAttrs (map
    (k: { name = rpmsLock.rpms.${k}.name; value = byKey.${k}; })
    (withArch "x86_64" ++ withArch "noarch"));
in
{
  inherit fetchSrpm fetchRpm;
  sources = builtins.mapAttrs (name: _: fetchSrpm name) lock.srpms;
  officialRpms = byKey // byName;
}
