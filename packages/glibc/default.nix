# Per-package overrides for the relocated glibc (docs/nix-native-design.md
# §8.1 field names, §11.5 S1 form).  DRAFT: lib/rocky/overrides.nix (WP6)
# owns the schema and validation; this file only uses §8.1 fields.  The FHS
# twin build (packages/glibc.nix) is unrelated and stays.
#
#   stage: the bootstrap stage building it (stage.name, stage.pkgs.<srpm>,
#          stage.libgccForGlibc, stage.glibcBuildDeps)
#   rocky: the final package set (unused in S1)
#
# Evidence: experiments/E4.md (opaqueRefs, lateReferrers),
# experiments/E5.md (trusted dirs), checks.nn-glibc-prep (nixPatches).
{ lib, stage, rocky }:
let
  # per late-bound output, the sibling outputs referencing it (transitive), from E4
  lateReferrers = import ./late-referrers.nix;
  sysroot = "sysroot_x86_64_el10_glibc/x86_64-redhat-linux/sys-root/el10/usr";
in
{
  # ---- recipe ---------------------------------------------------------------
  # libc_cv_{slibdir,rtlddir,complocaledir,rootsbindir} below the store prefix
  configSite = ./glibc.site;
  # P1 P2 P3 (§4.3), rebased onto Rocky's %prep result; applied by the prep
  # hook after %prep, in this order
  nixPatches = [
    ./nix-patches/ld-so-cache.patch
    ./nix-patches/locale-archive.patch
    ./nix-patches/ld-preload.patch
  ];
  env = {
    # ld.so must not get DT_RPATH (rtld asserts) and needs no self-rpath:
    # derivation attributes, read by the cc/ld wrappers
    NIX_NO_SELF_RPATH = "1";
    NIX_DONT_SET_RPATH = "1";
    # glibc dlopens libgcc_s.so.1 (pthread_cancel, backtrace) from its system
    # dirs only; a make variable from the environment (E5: reaches every
    # sub-make through rpmbuild and the spec's `env ... make -r`).  NOT a
    # shell identifier: mkRpmPackage must pass it on rpmbuild's command line
    # (`env 'user-defined-trusted-dirs=...' rpmbuild`), never in the
    # derivation's structured `env` (stdenv's setup.sh `declare -x` aborts on
    # it).  Fallback with the same effect: a configparms line (E5).
    "user-defined-trusted-dirs" =
      "${stage.libgccForGlibc}/lib64:${stage.libgccForGlibc}/lib";
  };
  # S1: kernel headers and the stage0 -devel deps (gd, png, z, selinux, audit,
  # cap, sdt.h) hoisted to store layout
  inputs.add = [ stage.pkgs.kernel-headers stage.glibcBuildDeps ];
  # --with-headers=%{_prefix}/include: resolved by the prefixView alias (E2);
  # only if E2 says otherwise:
  # specSubstitutions = [ { from = "--with-headers=%{_prefix}/include";
  #   to = "--with-headers=%{rocky_kernel_headers}/include"; count = 1; } ];
  doCheck = false;

  # ---- outputs --------------------------------------------------------------
  # functional merge: the 32-bit libc.so.6 / ld-linux.so.2 name $out/lib/...
  mergeOutputs = [ [ "glibc" "glibc32" ] ];
  runtimeSearchPaths = {
    "lib/locale/locale-archive" = "LOCALE_ARCHIVE"; # all_langpacks; P2
    "lib/locale" = "LOCPATH";                       # langpacks, common's C.utf8
    "share/i18n" = "I18NPATH";                      # locale_source
    "lib64/gconv" = "GCONV_PATH";                   # gconv_extra
  };
  unionDirs = {
    "lib64" = "rtld system dir; other outputs via RUNPATH";
    "lib/locale" = "LOCPATH";
    "share/locale" = "TEXTDOMAINDIR/profile";
  };
  # TZDIR default; profiles/NixOS set TZDIR (tzdata is another SRPM)
  danglingOk = [ "share/zoneinfo" ];
  # E4: copies of the prefix truncated after "-glibc-2.39-142.el10_" (gcc
  # stores the string by pieces: a 64-byte .rodata chunk + immediates), in
  # outputs other than out.  The full hash is inside the chunk, so Nix's
  # scanner registers the edge (all are -> out, which these outputs reference
  # anyway); only the path behind the piece is opaque to the partitioner.
  # Tail decoded from the immediates; see E4.md.
  opaqueRefs = [
    "common/bin/locale"                         # $out/lib/locale/... (LOCPATH)
    "common/bin/localedef"                      # $out/share/i18n/{locales,charmaps} (I18NPATH)
    "static/lib64/libc.a"                       # dl-load.o: $out/lib64/ (system dir)
    "${sysroot}/lib64/ld-linux-x86-64.so.2"     # $out/lib64/ (system dir)
    "${sysroot}/lib64/libc.a"                   # dl-load.o: $out/lib64/
  ];
  noPatchelf = [
    "lib64/ld-linux-x86-64.so.2" "lib/ld-linux.so.2" "lib64/lib*.so*" "lib/lib*.so*"
    "x86_64-redhat-linux/sys-root/**"
  ];
  # S1: memusagestat (utils) and makedb (nss_db) NEED libs that are not
  # Rocky-built yet (stage0 glibcBuildDeps); bound in S3 (lateBind)
  allowUnresolvedNeeded = lib.optionals (stage.name == "s1")
    [ "libgd.so.3" "libpng16.so.16" "libz.so.1" "libselinux.so.1" ];
  # active from S3; S1 allowlists the FHS shebangs instead (fhsAllowlist)
  lateBind = {
    common.interpreters = [ "bash" ];               # ldd, sotruss, tzselect
    # memusage, xtrace (bash), mtrace (sh -> perl); memusagestat NEEDs gd/png/z
    utils = { interpreters = [ "bash" "perl" ]; libs = [ "gd" "libpng" "zlib-ng" ]; };
    nss_db.libs = [ "libselinux" ];
    benchtests.interpreters = [ "bash" "python3" ];  # glibc-bench-compare, *bench*.py
  };
  inherit lateReferrers;
  fhsAllowlist = lib.optionalAttrs (stage.name == "s1") {
    "#!/usr/bin/bash" = "late-bound in S3";
    "#!/usr/bin/sh" = "mtrace (sh, then exec perl)";
    "#!/usr/bin/python3" = "benchtests scripts, late-bound in S3";
  };
}
