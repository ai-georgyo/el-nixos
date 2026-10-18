# checks.nn-cc-toolchain: the S1 cc-wrapper (nn.cc.wrap, design §5.1) with
# libc = nn.cc.stage0Libc, tested in a plain sandbox (lib/rocky/cc/toolchain-test.sh,
# the store-path port of bootstrap/tests/toolchain.sh): C, C++, -m32, -static,
# -flto programs build and run; PT_INTERP = the store loader; DT_RUNPATH, never
# DT_RPATH; self rpath $out/lib64; no store path in the DWARF; no -frandom-seed
# from the environment; and the same from PATH with an empty environment and
# Rocky's %build_cflags/%build_ldflags (mkRpmPackage's tool shim).
{ bootPkgs, self, ... }:
let
  pkgs = bootPkgs;
  cc = self.cc;
  wrapper = cc.stage0;
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
    # part B: nothing but the wrapper, a shell, coreutils and make (lto-wrapper
    # runs make for -flto=auto)
    PATH_B = pkgs.lib.makeBinPath [ wrapper pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnumake ];
    buildCommand = ''
      set +e -uo pipefail   # failures are counted by check()
      source ${../cc/toolchain-test.sh}
    '';
  };
}
