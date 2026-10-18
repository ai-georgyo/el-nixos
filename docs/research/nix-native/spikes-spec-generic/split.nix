# Spike: %files-driven split of a relocated rpmbuild result into one Nix
# output per subpackage, with length-preserving placeholder rewriting.
#   nix build --impure -f split.nix glibc      (outputs: out, common, devel, langpack-en, ...)
{ }:
let
  sp = import ./reloc-spike.nix { };
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  lp = f.legacyPackages.x86_64-linux;
  s = lp.stage0;
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;
  rpmsLock = lp.rpmsLock;

  outName = srpm: sub:
    if sub == srpm then "out"
    else if lib.hasPrefix "${srpm}-" sub then lib.removePrefix "${srpm}-" sub
    else sub;

  # built by the spec but absent from rpms.json (found by the spike: 8 of 20 SRPMs);
  # in the design this list comes from `rpmspec -q` at lock-generation time
  unshipped = {
    glibc = [ "glibc32" "sysroot-x86_64-el10-glibc" "compat-libpthread-nonshared" ];
    bzip2 = [ "bzip2-static" ]; expat = [ "expat-static" ]; gmp = [ "gmp-static" ]; lz4 = [ "lz4-static" ];
    ncurses = [ "ncurses-static" ]; popt = [ "popt-static" ]; xz = [ "xz-static" ];
  };

  split = { srpm, build, interp ? null, libdirs ? [ ], deps ? [ ] }:
    let
      e = s.lib.fetch.entry srpm;
      subs = lib.unique (map (k: rpmsLock.rpms.${k}.name) rpmsLock.bySrpm.${srpm}) ++ (unshipped.${srpm} or [ ]);
      names = map (outName srpm) subs;
      outputs = [ "out" ] ++ lib.remove "out" names;
      map' = pkgs.writeText "outputs-${srpm}" (lib.concatMapStrings (sub: "${sub} ${outName srpm sub}\n") subs);
    in
    assert lib.length (lib.unique names) == lib.length names;
    pkgs.stdenvNoCC.mkDerivation {
      name = "${srpm}-${e.version}-${e.release}";
      inherit outputs;
      nativeBuildInputs = [ pkgs.python3 pkgs.patchelf pkgs.cpio s.rpm ];
      buildCommand = ''
        set -euo pipefail
        export RPM_CONFIGDIR=${s.rpm}/usr/lib/rpm PATH=${s.rpm}/usr/bin:$PATH
        python3 - <<'EOF' > $TMPDIR/outputs.json
        import json, os
        m = {}
        for l in open("${map'}"):
            sub, o = l.split()
            m[sub] = os.environ[o]
        print(json.dumps(m))
        EOF
        mkdir -p $out
        python3 -I ${./split.py} --rpms ${build}/RPMS --prefix "$(cat ${build}/P)" \
          --outputs $TMPDIR/outputs.json --report $out/nix-support-split-report.json \
          ${lib.optionalString (interp != null) "--interp ${interp}"} \
          ${lib.concatMapStringsSep " " (d: "--libdir ${d}") libdirs}
      '';
      allowedReferences = outputs ++ deps;
      passthru = { inherit subs; };
    };

  glibc = split { srpm = "glibc"; build = sp.glibc.reloc; interp = "${builtins.placeholder "out"}/lib64/ld-linux-x86-64.so.2"; };
  ld = "${glibc}/lib64/ld-linux-x86-64.so.2";
  others = lib.genAttrs [ "which" "popt" "xz" "gzip" "libffi" "gmp" "libyaml" "m4" "sed" "diffutils" "libunistring" "redhat-rpm-config" "rocky-release" "attr" "bzip2" "expat" "lz4" "libsepol" "ncurses" "zlib-ng" ]
    (n: split { srpm = n; build = sp.reloc.${n}; interp = ld; deps = [ glibc ]; });
in
{ inherit glibc split; } // others
