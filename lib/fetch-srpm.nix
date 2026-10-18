# Fetch a Rocky source RPM as a fixed-output derivation.
#
#   fetchSrpm = import ./lib/fetch-srpm.nix { inherit (bootPkgs) fetchurl; inherit lock; };
#   fetchSrpm "glibc"   # -> /nix/store/...-glibc-2.39-142.el10_2.src.rpm
#
# `lock` is lock/rocky-<rel>/srpms.json (see docs/DESIGN.md). Every mirror is
# tried in order (pub first; vault once the release has been archived), and the
# file is checked against the sha256 from Rocky's repodata. This FOD is the
# only network access a build needs.
{ fetchurl, lock }:
let
  storeName = import ./store-name.nix;
in
name:
let
  s = lock.srpms.${name} or (throw "fetch-srpm: no SRPM named '${name}' in lock/rocky-${lock.release}/srpms.json");
in
fetchurl {
  name = storeName (baseNameOf s.path);
  urls = map (m: "${m}/${s.repo}/source/tree/${s.path}") lock.mirrors;
  sha256 = s.sha256;
  passthru = {
    srpmName = name;
    lockEntry = s;
    inherit (s) epoch version release;
  };
}
