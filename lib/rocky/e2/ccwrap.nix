# E2 only: nixpkgs cc-wrapper/bintools-wrapper around the stage0 (Rocky-source)
# toolchain, as in the [NF-S2] spike
# (docs/research/nix-native/spikes-nixpkgs-faithful/ccwrap.nix), with the flake
# arguments instead of getFlake.  The real S1 wrapper is WP4 (lib/rocky/cc/).
{ pkgs, stage0 }:
let
  s0 = stage0;
  # FHS-in-store trees -> top-level layout the wrappers expect (real dirs, symlinked files)
  hoist = name: tree: pkgs.runCommand name { passthru = { isGNU = true; version = "14"; }; } ''
    mkdir -p $out; cp -r ${tree}/usr/. $out/; chmod -R u+w $out
    # relocate GNU ld scripts (FHS absolute paths -> this tree)
    for f in $(find $out -name 'lib*.so' -size -4k); do
      if grep -q 'GNU ld script' "$(readlink -f $f)"; then
        sed -e "s, /lib64/, $out/lib64/,g; s, /usr/lib64/, $out/lib64/,g; s, /lib/, $out/lib/,g" "$(readlink -f $f)" > $f.new; rm $f; mv $f.new $f
      fi
    done
  '';
  gccShim = hoist "rocky-stage0-gcc-shim" s0.gcc;
  binutilsShim = hoist "rocky-stage0-binutils-shim" s0.binutils;
  # libc: the stage0 glibc tree (FHS paths inside), plus kernel headers in include
  libc = pkgs.runCommand "rocky-stage0-libc" { passthru = { libdir = "/usr/lib64/"; incdir = "/usr/include"; }; } ''
    mkdir -p $out; cp -rs ${s0.glibc}/. $out/; chmod -R u+w $out
    cp -rsn ${s0.kernelHeaders}/usr/include/. $out/usr/include/ || true
    for f in $out/usr/lib64/libc.so $out/usr/lib64/libm.so; do
      sed -e "s, /lib64/, $out/usr/lib64/,g; s, /usr/lib64/, $out/usr/lib64/,g" "$(readlink -f $f)" > $f.new; rm $f; mv $f.new $f
    done
  '';
  bintools = (pkgs.wrapBintoolsWith { bintools = binutilsShim; inherit libc; }).overrideAttrs (o: {
    postFixup = o.postFixup + ''
      echo ${libc}/usr/lib64/ld-linux-x86-64.so.2 > $out/nix-support/dynamic-linker
    '';
  });
  cc = (pkgs.wrapCCWith { cc = gccShim; inherit bintools libc; }).overrideAttrs (o: {
    postFixup = o.postFixup + ''
      : > $out/nix-support/cc-cflags-before   # no nixpkgs frame-pointer/machine flags
    '';
  });
in
{ inherit cc bintools libc; }
