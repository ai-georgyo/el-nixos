# nn.lateBind: the bind derivation of design §2.9 / §11.3 (lib/rocky/late-bind.nix,
# builder lib/rocky/late-bind/late-bind.py):
#
#   nn.lateBind.wrap raw { binds = { common.interpreters = [ bash ]; utils.libs = [ gd ]; };
#                          referrers = { common = [ "langpack_*" ]; }; }
#     -> raw // { common = <bound>; langpack_* = <bound>; utils = <bound>; raw; bound; lateBound; }
#   nn.lateBind.fromOverrides { pkgs; } overrides -> { binds; referrers; }   (names -> packages)
#   nn.lateBind.mk { stdenvNoCC patchelf python3 partitionTool } -> the same over other tools
{ bootPkgs, lib, self, ... }:
import ../late-bind.nix { inherit lib bootPkgs; inherit (self) partitionTool; }
