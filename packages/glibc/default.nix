# Per-package overrides for the relocated glibc (docs/nix-native-design.md
# §8.1 field names, §11.5 S1 form; schema: lib/rocky/overrides.nix,
# packages/README-overrides.md).  rockyBoot.s1.glibc = milestone M1
# (docs/research/nix-native/experiments/wp7.md).  The FHS twin build
# (packages/glibc.nix) is unrelated and stays.
#
#   stage: the bootstrap stage building it (stage.name, stage.pkgs.<srpm>,
#          stage.libgccForGlibc, stage.glibcBuildDeps)
#   rocky: the final package set (unused in S1)
#
# Evidence: experiments/E4.md (opaqueRefs, lateReferrers),
# experiments/E5.md (trusted dirs), checks.nn-glibc-prep (nixPatches),
# tools/rocky-partition/tests/glibc-overrides.nix (the partition replay:
# danglingOk, prefixRelativeOk, opaqueRefs), experiments/wp7.md (the build).
{ lib, stage, rocky }:
let
  # per late-bound output, the sibling outputs referencing it (transitive), from E4
  lateReferrers = import ./late-referrers.nix;
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
    # the S1 ld wrapper puts --enable-new-dtags before every link (so its
    # store -rpath entries become DT_RUNPATH, lib/rocky/cc/wrap.nix); glibc
    # gets no store rpath at all (NIX_DONT_SET_RPATH), and with new dtags ld
    # writes `-z now` as DT_FLAGS/DF_BIND_NOW instead of Rocky's DT_BIND_NOW
    # and the gconv modules' -rpath '$ORIGIN' as DT_RUNPATH instead of
    # DT_RPATH (RUNPATH yields to LD_LIBRARY_PATH): 705 abi.dynamic and 279
    # content differences in checks.nn-glibc-{abi,content} (M1, m1.md).
    # NIX_LDFLAGS_BEFORE follows the wrapper's own flags and precedes the
    # link's arguments, so this restores Rocky's ld default and still lets
    # glibc's own -Wl,--enable-new-dtags (rt/Makefile, librt.so.1) win; as
    # NIX_LDFLAGS_AFTER it overrode that one too (librt lost its DT_FLAGS)
    NIX_LDFLAGS_BEFORE = "--disable-new-dtags";
    # glibc dlopens libgcc_s.so.1 (pthread_cancel, backtrace) from its system
    # dirs only; a make variable from the environment (E5: reaches every
    # sub-make through rpmbuild and the spec's `env ... make -r`).  NOT a
    # shell identifier: mkRpmPackage must pass it on rpmbuild's command line
    # (`env 'user-defined-trusted-dirs=...' rpmbuild`), never in the
    # derivation's structured `env` (stdenv's setup.sh `declare -x` aborts on
    # it).  overrides.nix should assert that every non-identifier key here
    # takes that route.  Fallback with the same effect, verified in E5 part 3
    # (configparms in the source dir, where the prep hook runs; it wins over
    # the environment): drop this entry and use
    #   prepScript = ''
    #     echo 'user-defined-trusted-dirs=<same value>' > configparms
    #   '';
    "user-defined-trusted-dirs" =
      "${stage.libgccForGlibc}/lib64:${stage.libgccForGlibc}/lib";
  };
  # kernel headers and the -devel deps (gd, png, z, selinux, audit, cap,
  # sdt.h) in store layout, in every stage.  S1: stage.glibcBuildDeps = the
  # stage0 ones, hoisted.  What S3a's stage provides here (gd, libpng and
  # libselinux are not Rocky-built before S3d, and S3 inputs must be S2/S3
  # builds, §7.3) is mkStage's decision (WP6/WP11), not this file's.
  # Both are build-only (host + view, never runtime inputs): glibc-devel
  # Requires kernel-headers in Rocky, but M1's closure is the siblings +
  # libgccForGlibc; consumers get the kernel headers from the toolchain
  # (nn.cc.libcAdapter `headers`, nn.stages.s1.glibc1Libc), and a reference
  # from any glibc output to kernel-headers fails the partition
  # (foreign-store-path) and outputChecks.
  inputs.addBuildOnly = [ stage.pkgs.kernel-headers stage.glibcBuildDeps ];
  # --with-headers=%{_prefix}/include: resolved by the prefixView alias (E2,
  # through the view's include/ = kernel-headers'); only if E2 says otherwise:
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
  danglingOk = [
    # TZDIR default; profiles/NixOS set TZDIR (tzdata is another SRPM)
    "share/zoneinfo"
    # partition replay (tools/rocky-partition/tests/glibc-overrides.nix):
    "libx32"              # ldd's RTLDLIST names the x32 loader, never built
    "lib/gconv"           # the 32-bit libc (glibc32, merged into out) names its
                          # gconv dir; Rocky ships no 32-bit gconv modules
    "lib/libmemusage.so"  # memusage preloads $utils/$LIB/libmemusage.so: the
                          # lib64 expansion is utils', the lib one (32-bit) does
                          # not exist (no 32-bit memusage in Rocky either)
  ];
  # partition replay: non-prefix outputs that name the bare prefix or a
  # top-level dir several outputs fill, on purpose
  prefixRelativeOk = [
    "benchtests"          # glibc's test support (support/support_paths.c) is
                          # linked in: bare $out, $out/bin, $out/sbin, ... in a
                          # fixed-size table
    "sysroot_x86_64_el10_glibc"  # the cross sysroot's copies (ld.so, libc.a): a
                                 # sysroot for a cross gcc, never run from there
  ];
  # store-by-pieces references to $out in outputs other than out (design
  # §2.8, E4 + the replay).  The truncated copies keep the full hash, so Nix's
  # scanner registers the edge (all are -> out, which these outputs reference
  # anyway; the partitioner adds nix-support/hidden-references as well); only
  # the path behind the piece is opaque.  Format: PLAN.md output patterns.
  opaqueRefs = [
    "common:bin/locale"           # $out/lib/locale/... (LOCPATH)
    "common:bin/localedef"        # $out/share/i18n/{locales,charmaps} (I18NPATH)
    "static:lib64/libc.a"         # dl-load.o: $out/lib64/ (system dir)
    "benchtests"                  # support_paths.c table (above)
    "sysroot_x86_64_el10_glibc"   # ld-linux-x86-64.so.2, libc.a: $out/lib64/
  ];
  noPatchelf = [
    "lib64/ld-linux-x86-64.so.2" "lib/ld-linux.so.2" "lib64/lib*.so*" "lib/lib*.so*"
    "x86_64-redhat-linux/sys-root/**"
  ];
  # S1: memusagestat (utils) and makedb (nss_db) NEED libs that are not
  # Rocky-built yet (stage0 glibcBuildDeps); bound in S3 (lateBind).
  # S3 has neither this list nor fhsAllowlist on purpose: the raw utils,
  # nss_db, common and benchtests outputs still carry these NEEDED and the
  # FHS shebangs there, and are accepted because the output is in lateBind
  # with that library (§2.6 step 4) or interpreter (assumed to be the same
  # rule).  The soname <-> lateBind library mapping and the shebang side of
  # the rule belong to WP6/WP11 (rocky-partition, lateBind); if they decide
  # otherwise, these two conditions must cover S3's raw late outputs too.
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
