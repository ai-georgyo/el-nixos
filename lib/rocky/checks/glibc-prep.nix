# glibc WP0d checks (docs/nix-native-design.md §4.3, §4.5):
#
#   nn-glibc-prep         Rocky's %prep of the glibc SRPM (rpmbuild -rp in the
#                         stage0 buildroot), then every Nix-side patch of
#                         packages/glibc/default.nix (nixPatches) with
#                         `patch -p1 --dry-run --fuzz=0`, then all applied in
#                         order (packages/glibc/prep.nix)
#   nn-libgcc-for-glibc   nn.libgccForGlibc references nothing (its closure is
#                         itself), holds no store path string, has no
#                         RPATH/RUNPATH; 64-bit in lib64, 32-bit in lib
{ bootPkgs, lib, stage0, repo, self, ... }:
let
  # only nixPatches is read: the stage is never forced
  overrides = import (repo + "/packages/glibc/default.nix") {
    inherit lib;
    stage = throw "checks.nn-glibc-prep: only nixPatches is read";
    rocky = null;
  };
  lg = self.libgccForGlibc;
in
{
  nn-glibc-prep = import (repo + "/packages/glibc/prep.nix") {
    inherit bootPkgs lib stage0;
    patches = overrides.nixPatches;
  };

  nn-libgcc-for-glibc = bootPkgs.runCommand "nn-libgcc-for-glibc"
    {
      nativeBuildInputs = [ bootPkgs.binutils-unwrapped ];
      # "<path>\n<deriver>\n<number of references>\n<references...>" per path
      exportReferencesGraph = [ "closure" lg ];
    } ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    {
      [ "$(sed -n 1p closure)" = ${lg} ] || fail "closure does not start with ${lg}"
      [ "$(sed -n 3p closure)" = 0 ] || fail "${lg} has references: $(tail -n +4 closure | tr '\n' ' ')"
      [ "$(grep -c '^/nix/store/' closure)" = 1 ] || fail "closure is more than the copy itself"
      echo "OK    closure = ${lg} only, 0 references"
      for f in lib64/libgcc_s.so.1 lib/libgcc_s.so.1; do
        ! grep -q /nix/store ${lg}/$f || fail "$f contains a store path string"
        d=$(readelf -dW ${lg}/$f)
        ! grep -qE '\((RPATH|RUNPATH)\)' <<<"$d" || fail "$f has RPATH/RUNPATH"
        grep -q 'Library soname: \[libgcc_s.so.1\]' <<<"$d" || fail "$f: SONAME"
        echo "OK    $f: no store path, no RPATH/RUNPATH, SONAME libgcc_s.so.1, NEEDED $(grep -o 'Shared library: \[[^]]*\]' <<<"$d" | sed 's/Shared library: //' | tr '\n' ' ')"
      done
      readelf -hW ${lg}/lib64/libgcc_s.so.1 | grep -q 'Class: *ELF64' || fail "lib64/libgcc_s.so.1 is not ELF64"
      readelf -hW ${lg}/lib/libgcc_s.so.1 | grep -q 'Class: *ELF32' || fail "lib/libgcc_s.so.1 is not ELF32"
      echo "OK    lib64: ELF64, lib: ELF32"
    } | tee $out
  '';
}
