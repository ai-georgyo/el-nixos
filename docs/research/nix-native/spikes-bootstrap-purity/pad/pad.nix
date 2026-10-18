let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  glibc = pkgs.stdenv.cc.libc;
in pkgs.runCommand "slash-pad-test" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
  set -eu
  mkdir -p $out/bin
  cp ${pkgs.hello}/bin/hello $out/bin/hello; chmod u+w $out/bin/hello
  orig_interp=$(patchelf --print-interpreter $out/bin/hello)
  # insert 20 extra slashes after the store path name of glibc in PT_INTERP and RUNPATH
  pad=$(printf '/%.0s' $(seq 20))
  padded=$(echo "$orig_interp" | sed "s|^\(/nix/store/[^/]*\)/|\1$pad/|")
  patchelf --set-interpreter "$padded" --set-rpath "${glibc}$pad/lib" $out/bin/hello
  patchelf --print-interpreter $out/bin/hello > $out/interp.txt
  patchelf --print-rpath $out/bin/hello >> $out/interp.txt
  $out/bin/hello > $out/run.txt
  # Nix reference scanning must still see glibc (hash is unchanged) -- and nothing else from hello
  echo "${glibc}$pad/lib/libc.so.6" > $out/text-ref
''
