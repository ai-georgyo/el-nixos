# Spike S5: one Nix output per RPM subpackage, from the relocated single-prefix build (S3).
# Simulates the in-build partition step: S3's prefix hash is first rewritten to this
# derivation's $out (equal length: same name), then partition.py places the files and
# fixes/validates references; Nix then checks the outputs for cycles itself.
{ merges ? [ ] }:
let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  r = f.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;
  built = import ./glibc-reloc.nix;
  srpm = "glibc";
  subpkgs = lib.unique (map (k: r.rpmsLock.rpms.${k}.name) r.rpmsLock.bySrpm.${srpm})
    ++ [ "glibc32" "sysroot-x86_64-el10-glibc" "compat-libpthread-nonshared" ];
  special = { "${srpm}" = "out"; "${srpm}-devel" = "dev"; "${srpm}-static" = "static"; "${srpm}-doc" = "doc"; "${srpm}-libs" = "lib"; };
  outName = n: special.${n} or (lib.replaceStrings [ "-" "." "+" ] [ "_" "_" "_" ] (lib.removePrefix "${srpm}-" n));
  rep = n: let m = lib.findFirst (g: lib.elem n g) null merges; in if m == null then n else lib.head m;
  smap = lib.genAttrs subpkgs (n: outName (rep n));
  outputs = lib.unique ([ "out" ] ++ lib.attrValues smap);
in pkgs.stdenvNoCC.mkDerivation {
  name = "glibc-2.39-142.el10_2";
  inherit outputs;
  nativeBuildInputs = [ pkgs.python3 ];
  passAsFile = [ "smap" ];
  smap = builtins.toJSON smap;
  passthru = { inherit smap; };
  buildCommand = ''
    B=${built}
    cp -a $B/. $TMPDIR/tree; chmod -R u+w $TMPDIR/tree
    python3 - $TMPDIR/tree "$B" "$out" <<'PY'
import os, sys
root, old, new = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
assert len(old) == len(new)
for d, ds, fs in os.walk(root):
    for n in fs + ds:
        p = os.path.join(d, n)
        if os.path.islink(p):
            t = os.readlink(p)
            if old.decode() in t:
                os.unlink(p); os.symlink(t.replace(old.decode(), new.decode()), p)
        elif os.path.isfile(p):
            b = open(p, 'rb').read()
            if old in b: open(p, 'wb').write(b.replace(old, new))
PY
    mkdir -p $TMPDIR/report
    python3 ${./partition.py} $TMPDIR/tree "$out" $TMPDIR/tree/nix-support/rpm-files $smapPath $TMPDIR/report/partition.txt || { echo "partition: cycles"; exit 1; }
    mkdir -p $out/nix-support; cp $TMPDIR/report/partition.txt $out/nix-support/
  '';
}
