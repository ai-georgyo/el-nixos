# Temporary SRPM fetcher driven by the seed lock (lock/rocky-<rel>/srpms.json).
# The lock-generator track owns lib/fetch-srpm.nix; the integrator reconciles.
#
#   fetchSrpm "glibc"  -> /nix/store/...-glibc-2.39-142.el10_2.src.rpm
#   unpackSrpm "glibc" -> /nix/store/...-glibc-2.39-142.el10_2-srpm/{glibc.spec,*.tar.xz,*.patch}
{ pkgs, lock }:
let
  inherit (pkgs) lib;

  entry = name:
    lock.srpms.${name} or (throw "SRPM '${name}' is not in the lock (lock/rocky-${lock.release}/srpms.json)");

  fetchSrpm = name:
    let e = entry name; in
    pkgs.fetchurl {
      name = baseNameOf e.path;
      urls = map (m: "${m}/${e.repo}/source/tree/${e.path}") lock.mirrors;
      sha256 = e.sha256;
      passthru = { srpmName = name; lockEntry = e; };
    };

  # All files of an SRPM (spec, tarballs, patches) in one directory.
  # bsdtar reads the rpm container directly (no rpm2cpio needed).
  unpackSrpm = name:
    let src = fetchSrpm name; e = entry name; in
    pkgs.runCommand "${name}-${e.version}-${e.release}-srpm"
      {
        nativeBuildInputs = [ pkgs.libarchive ];
        passthru = { inherit src; srpmName = name; lockEntry = e; };
      } ''
      mkdir -p $out
      bsdtar -xf ${src} -C $out
      chmod -R u+w,go-w $out
    '';

  # "%dist" a package was built with, recovered from its lock release
  # ("142.el10_2" -> ".el10_2", "295-1.el10.rocky.0.2" -> ".el10"), so rebuilt
  # NEVRs match the official ones; falls back to the lock-wide dist.
  distOf = name:
    let
      m = builtins.match ".*(\\.el[0-9]+(_[0-9]+)?).*" (entry name).release;
    in if m == null then lock.dist else builtins.head m;
in
{
  inherit fetchSrpm unpackSrpm distOf entry;
}
