# checks.nn-cc-toolchain: the S1 cc-wrapper (nn.cc.wrap, design §5.1) with
# libc = nn.cc.stage0Libc, tested in a plain sandbox (lib/rocky/cc/toolchain-test.sh,
# the store-path port of bootstrap/tests/toolchain.sh): C, C++, -m32, -static,
# -flto programs build and run; PT_INTERP = the store loader; DT_RUNPATH, never
# DT_RPATH; self rpath $out/lib64; no store path in the DWARF; no -frandom-seed
# from the environment; prefix maps for symlink-farm system include dirs,
# -include files, store sources and NIX_ROCKY_MAP_ROOTS; -I/-L/-rpath under a
# /usr view kept although stdenv sets NIX_ENFORCE_PURITY=1; slim-LTO archives;
# and the same from PATH with an empty environment and Rocky's
# %build_cflags/%build_ldflags (mkRpmPackage's tool shim).
{ bootPkgs, self, ... }:
let
  pkgs = bootPkgs;
  cc = self.cc;
  wrapper = cc.stage0;
  # part C: the same libc split into out/dev as the relocated glibc will be
  split = import ../cc/stage0-libc-split.nix { inherit bootPkgs; inherit (cc) stage0Libc; };
  wrapperSplit = cc.wrap { libc = split; name = "rocky-s1-splitlibc"; };
  # prefix-map fixtures (passed as strings, not inputs: NIX_ROCKY_MAP_ROOTS
  # does not name them).  farmT/farmTF have short names, the farm a long
  # one: its symlinks are longer than their targets, so gcc names the
  # headers by the targets (-fcanonical-system-headers), as with E1's
  # hoisted build deps (cp -rs of an FHS tree: sdt.h).
  farmT = pkgs.runCommand "rh" { } ''
    mkdir -p $out/include
    echo 'static inline int rocky_farm(int x) { return x + 1; }' > $out/include/rocky-farm.h
    printf '#include <stdio.h>\nint main(void) { puts(__FILE__); return 0; }\n' > $out/rocky-src.c
  '';
  farmTF = pkgs.runCommand "rf" { } ''
    mkdir -p $out/usr/include
    echo 'static inline int rocky_fhs(int x) { return x + 2; }' > $out/usr/include/rocky-fhs.h
  '';
  farm = pkgs.runCommand "include-farm-of-symlinks-with-a-rather-long-name-for-the-nn-cc-check" { } ''
    mkdir -p $out/include
    cp -rs ${farmT}/include/. $out/include/
    cp -rs ${farmTF}/usr/include/. $out/include/
  '';
  absHdr = pkgs.runCommand "rocky-abs-hdr" { } ''
    mkdir -p $out/include
    echo 'static inline int rocky_abs(int x) { return x; }' > $out/include/rocky-abs.h
  '';
in
{
  nn-cc-toolchain = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-cc-toolchain";
    nativeBuildInputs = [ wrapper ];
    WRAPPER = wrapper;
    LIBC = cc.stage0Libc.out;
    GCC = cc.gcc;
    BINUTILS = cc.binutils;
    STORESCAN = cc.storescan;
    ROCKY_FLAGS = cc.rpmConfig.flags;
    PYTHON = "${pkgs.python3}/bin/python3";
    BWRAP = "${pkgs.bubblewrap}/bin/bwrap";
    FARM = farm;
    FARM_T = farmT;
    FARM_TF = farmTF;
    ABS_HDR = absHdr;
    # part B: nothing but the wrapper, a shell, coreutils and make (lto-wrapper
    # runs make for -flto=auto)
    PATH_B = pkgs.lib.makeBinPath [ wrapper pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnumake ];
    PATH_C = pkgs.lib.makeBinPath [ wrapperSplit pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnumake ];
    WRAPPER_C = wrapperSplit;
    LIBC_OUT = split.out;
    LIBC_DEV = split.dev;
    buildCommand = ''
      set +e -uo pipefail   # failures are counted by check()
      source ${../cc/toolchain-test.sh}
    '';
  };
}
