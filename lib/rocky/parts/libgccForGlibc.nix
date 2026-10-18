# nn.libgccForGlibc: RPATH-free copy of the stage0 gcc's libgcc_s.so.1
# (64-bit in lib64, 32-bit in lib) for the S1 glibc's trusted dirs.
# References nothing.  bootstrap/nn/libgcc-for-glibc.nix, design §4.5.
{ bootPkgs, stage0, ... }:
let e = stage0.lib.fetch.entry "gcc"; in
import ../../../bootstrap/nn/libgcc-for-glibc.nix {
  inherit bootPkgs;
  src = stage0.gcc;
  version = "${e.version}-${e.release}";
  stage = "s0";
}
