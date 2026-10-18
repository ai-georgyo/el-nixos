let f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos"; pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; ccw = import ./ccwrap.nix;
in pkgs.stdenvNoCC.mkDerivation { name = "rpathtest"; nativeBuildInputs = [ ccw.cc ccw.bintools pkgs.binutils-unwrapped ]; buildCommand = ''
  echo 'int main(){return 0;}' > t.c
  env | grep -E '^NIX_(CC|BINTOOLS)_WRAPPER_TARGET' || true
  NIX_DONT_SET_RPATH=1 NIX_NO_SELF_RPATH=1 gcc t.c -o a; readelf -d a | grep -i path || echo "no rpath (unsalted)"
  NIX_DEBUG=1 NIX_DONT_SET_RPATH=1 NIX_NO_SELF_RPATH=1 gcc -shared -nostdlib t.c -lgcc -o b.so 2>&1 | grep -iA1 'rpath' | head; readelf -d b.so | grep -i path || echo "no rpath b.so"
  touch $out''; }
