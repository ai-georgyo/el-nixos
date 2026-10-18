# Fetch an *official* Rocky binary RPM (for verification comparisons only;
# nothing we build may depend on these).
#
#   fetchRpm = import ./lib/fetch-rpm.nix { inherit (bootPkgs) fetchurl; rpmsLock = ...; };
#   fetchRpm "glibc.x86_64"
#
# `rpmsLock` is lock/rocky-<rel>/rpms.json (format documented in
# tools/update-lock.py). URL = <mirror>/<repo>/x86_64/os/<path>.
{ fetchurl, rpmsLock }:
let
  storeName = import ./store-name.nix;
in
key:
let
  r = rpmsLock.rpms.${key} or (throw "fetch-rpm: no binary RPM '${key}' (use <name>.<arch>) in lock/rocky-${rpmsLock.release}/rpms.json");
in
fetchurl {
  name = storeName (baseNameOf r.path);
  urls = map (m: "${m}/${r.repo}/x86_64/os/${r.path}") rpmsLock.mirrors;
  sha256 = r.sha256;
  passthru = {
    lockEntry = r;
    rpmName = r.name;
    inherit (r) arch epoch version release srpm;
  };
}
