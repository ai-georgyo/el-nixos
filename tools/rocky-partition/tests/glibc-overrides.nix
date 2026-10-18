# Partition plan entries for glibc (design §11.5, the S1 form) as validated by
# the replay check (lib/rocky/checks/partition.nix, nn-partition-replay).
# Additions to §11.5, each found by the replay and explained here:
#   danglingOk  libx32       ldd's RTLDLIST names the x32 loader, never built
#               lib/gconv    32-bit libc (glibc32, merged into out) names its
#                            gconv dir; Rocky ships no 32-bit gconv modules
#               lib/libmemusage.so
#                            memusage loads $utils/\$LIB/libmemusage.so: the
#                            lib64 expansion is utils', the lib one (32-bit,
#                            glibc32, unshipped) is out's and is not found
#                            there: no 32-bit memusage
#   prefixRelativeOk + opaqueRefs
#               benchtests   glibc's test support (support/support_paths.c) is
#                            linked in: bare $out, $out/bin, $out/sbin, ... in a
#                            fixed-size table (also stored by pieces)
#               sysroot_*    the cross sysroot's copy of ld.so: not run from there
#   opaqueRefs  common:bin/locale, common:bin/localedef
#                            store-by-pieces copies of the prefix ([F-2], E4)
{
  mergeOutputs = [ [ "glibc" "glibc32" ] ];
  runtimeSearchPaths = {
    "lib/locale/locale-archive" = "LOCALE_ARCHIVE";
    "lib/locale" = "LOCPATH";
    "share/i18n" = "I18NPATH";
    "lib64/gconv" = "GCONV_PATH";
  };
  unionDirs = {
    "lib64" = "rtld system dir; other outputs via RUNPATH";
    "lib/locale" = "LOCPATH";
    "share/locale" = "TEXTDOMAINDIR/profile";
  };
  danglingOk = [ "share/zoneinfo" "libx32" "lib/gconv" "lib/libmemusage.so" ];
  prefixRelativeOk = [ "benchtests" "sysroot_x86_64_el10_glibc" ];
  opaqueRefs = [ "benchtests" "sysroot_x86_64_el10_glibc" "common:bin/locale" "common:bin/localedef" ];
  noPatchelf = [ "lib64/ld-linux-x86-64.so.2" "lib/ld-linux.so.2" "lib64/lib*.so*" "lib/lib*.so*"
                 "x86_64-redhat-linux/sys-root/**" ];
  systemLibDirs = [ "@out@/lib64" "@out@/lib" ];
  allowUnresolvedNeeded = [ "libgd.so.3" "libpng16.so.16" "libz.so.1" "libselinux.so.1" ];
  lateBind = {
    common.interpreters = [ "bash" ];
    utils = { interpreters = [ "bash" "perl" ]; libs = [ "gd" "libpng" "zlib-ng" ]; };
    nss_db.libs = [ "libselinux" ];
  };
  lateReferrers = { common = [ "minimal_langpack" "langpack_*" ]; nss_db = [ "nss_devel" ]; utils = [ ]; };
  fhsAllowlist = { "#!/usr/bin/bash" = "late-bound in S3"; "#!/usr/bin/sh" = "mtrace"; };
}
