# libgcc_s.so.1 for glibc's trusted directories (docs/nix-native-design.md §4.5).
#
# glibc dlopens libgcc_s.so.1 (pthread_cancel, pthread_exit, backtrace) by
# soname, searching only its compiled-in system dirs.  The relocated glibc has
# no /lib64, so it gets
#   user-defined-trusted-dirs = $libgccForGlibc/lib64:$libgccForGlibc/lib
# (the nixpkgs mechanism, experiments/E5.md).  This is a *copy* of the
# previous stage's libgcc_s with any RPATH/RUNPATH removed: libgcc_s NEEDs
# only libc.so.6 / ld-linux*, which are always loaded when glibc dlopens it,
# so the copy references nothing and pulls no previous-stage glibc (or gcc)
# into glibc's closure (allowedReferences = [ ]).  If a program already loaded
# a libgcc_s.so.1 through its own RUNPATH, the loader reuses it by soname.
#
#   S1: stage0 gcc's libgcc_s (named bootstrap exception, §0.4.1)
#   S3: gcc¹'s libgcc output (lib64 = "lib64", lib32 = "lib")
{ bootPkgs
, src                 # tree with the 64-bit and 32-bit libgcc_s.so.1
, lib64 ? "usr/lib64" # their directories below src (stage0 gcc: an FHS tree)
, lib32 ? "usr/lib"
, version             # gcc version-release, for the store name
, stage ? "s0"        # the stage `src` belongs to (passthru.rockyStage)
}:
bootPkgs.runCommand "libgcc-s-${version}"
{
  nativeBuildInputs = [ bootPkgs.patchelf bootPkgs.binutils-unwrapped ];
  allowedReferences = [ ];
  passthru = { rockyStage = stage; inherit src; };
} ''
  set -euo pipefail
  install -Dm755 ${src}/${lib64}/libgcc_s.so.1 $out/lib64/libgcc_s.so.1
  install -Dm755 ${src}/${lib32}/libgcc_s.so.1 $out/lib/libgcc_s.so.1
  for f in $out/lib64/libgcc_s.so.1 $out/lib/libgcc_s.so.1; do
    # a no-op (bytes unchanged) when there is none, as for stage0's FHS build
    patchelf --remove-rpath $f
    d=$(readelf -dW $f)
    if grep -E '\((RPATH|RUNPATH)\)' <<<"$d"; then echo "$f: still has a search path" >&2; exit 1; fi
    grep -q 'Library soname: \[libgcc_s.so.1\]' <<<"$d" || { echo "$f: wrong SONAME" >&2; exit 1; }
    # NEEDED: the libc that dlopens it, nothing else
    bad=$(grep -o 'Shared library: \[[^]]*\]' <<<"$d" | grep -vE '\[(libc\.so\.6|ld-linux(-x86-64)?\.so\.2)\]' || true)
    [ -z "$bad" ] || { echo "$f: unexpected NEEDED: $bad" >&2; exit 1; }
  done
  [ "$(readelf -hW $out/lib64/libgcc_s.so.1 | grep -c 'ELF64')" = 1 ]
  [ "$(readelf -hW $out/lib/libgcc_s.so.1 | grep -c 'ELF32')" = 1 ]
''
