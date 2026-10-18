# nn.cc: the S1 C toolchain (lib/rocky/cc/wrap.nix, design §5.1) and the E1
# experiment (lib/rocky/cc/e1-glibc.nix, docs/research/nix-native/experiments/E1.md).
#   nn.cc.wrap { libc = { out; dev; }; }   wrapped gcc/g++/cpp + binutils
#   nn.cc.stage0Libc                       stage0 glibc + kernel headers, relocated
#   nn.cc.stage0                           nn.cc.wrap { libc = nn.cc.stage0Libc; }
#   nn.cc.storescan                        store-path scanner (full + pieced, DWARF-aware)
#   nn.cc.rpmConfig.{config,flags}         stage0 /usr/lib/rpm tree; Rocky's evaluated cflags/ldflags
#   nn.cc.e1.{glibc,report}                E1: relocated glibc through nn.cc.stage0
args:
let
  cc = import ../cc/wrap.nix args;
in
cc // {
  storescan = ../cc/storescan.py;
  rpmConfig = import ../cc/rpm-config.nix { inherit (args) bootPkgs lib stage0; };
  e1 = import ../cc/e1-glibc.nix (args // { inherit cc; });
}
