# checks.nn-s1-glibc1: the S1 packages after glibc¹ (nn.stages.s1Glibc1:
# which, xz, zlib-ng, gzip built with ccGlibc1 against rockyBoot.s1.glibc),
# the design's next S1 step.  The M1 review found every such package
# failing outputChecks: patchelf --remove-rpath left the cc wrapper's old
# RUNPATH string (the libc dev output and the gcc copy) in .dynstr, which
# Nix's scanner counts as references; the partitioner had reported 0
# errors.  Build time, in a plain sandbox (no /usr):
#   * partition reports: 0 errors
#   * closures: own outputs + glibc¹'s out and its requisites (glibc out,
#     libgccForGlibc) only -- no gcc copy, no glibc dev, no stage0 libc
#   * no byte of a build-only store path (the gcc copy, glibc dev, the
#     stage0 libc tree) left in any file of the outputs
#   * RUNPATH as recomputed: libc from the loader's system dir (no RUNPATH
#     entry for it); xz -> $lib/lib64; never DT_RPATH with a store dir
#   * Rocky's dtags: BIND_NOW libraries keep DT_BIND_NOW (mkRpmPackage's
#     --disable-new-dtags; liblzma has `-z now`)
#   * the programs run: which, xz round trip, gzip round trip; a program
#     built by ccGlibc1 against xz.dev links and runs
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  g1 = self.stages.s1Glibc1;
  glibc = g1.pkgs.glibc;
  inherit (g1.pkgs) which xz gzip;
  zlib = g1.pkgs.zlib-ng;
  pkgOutputs = p: map (o: p.${o}) (lib.remove "logs" p.outputs);
  pkgsT = { inherit which xz gzip zlib; };

  lzmaUser = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-s1-glibc1-lzma-user";
    nativeBuildInputs = [ g1.ccGlibc1 ];
    buildInputs = [ xz.dev ];
    strictDeps = true;
    dontUnpack = true;
    buildPhase = ''
      cat > t.c <<'EOF'
      #include <lzma.h>
      #include <stdio.h>
      int main(void) { printf("liblzma %s\n", lzma_version_string()); return 0; }
      EOF
      gcc -O2 -o lzma-user t.c -llzma
    '';
    installPhase = "mkdir -p $out/bin; cp lzma-user $out/bin/";
  };

  evalTests = {
    "every S1 package after glibc¹ links glibc¹ (not the stage0 libc)" =
      lib.all (p: lib.elem "${glibc.out}" p.rockyPlan.allowedStorePaths) (lib.attrValues pkgsT);
    "glibc itself still uses the stage0 libc and cc" = g1.pkgs.glibc.drvPath == self.stages.s1.pkgs.glibc.drvPath;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) evalTests);
in
{
  nn-s1-glibc1 = assert lib.assertMsg (failed == [ ]) ("nn-s1-glibc1 eval tests failed: " + lib.concatStringsSep "; " failed);
  pkgs.runCommand "nn-s1-glibc1" {
    __structuredAttrs = true;
    nativeBuildInputs = [ pkgs.python3 pkgs.binutils ];
    exportReferencesGraph = lib.mapAttrs (_: pkgOutputs) pkgsT;
    own = lib.mapAttrs (_: p: map toString (pkgOutputs p)) pkgsT;
    allowed = map toString ([ glibc.out ] ++ glibc.rockyRequisites);
    # build-only paths whose hash must not be anywhere in an output
    buildOnly = map toString [ g1.ccGlibc1 self.cc.gcc self.cc.binutils glibc.dev glibc.static g1.stage0LibcTree ];
    outs = lib.mapAttrs (_: p: map toString (pkgOutputs p)) pkgsT;
    glibcOut = "${glibc.out}";
    whichOut = "${which.out}";
    xzOut = "${xz.out}";
    xzLib = "${xz.lib}";
    gzipOut = "${gzip.out}";
    user = "${lzmaUser}";
    evalSummary = lib.attrNames evalTests;
  } ''
    set -euo pipefail
    log() { echo "$*" | tee -a $TMPDIR/result.txt; }
    fail=0
    check() { if eval "$2"; then log "PASS $1"; else log "FAIL $1"; fail=1; fi; }
    for t in "''${evalSummary[@]}"; do log "PASS (eval) $t"; done

    check "partition reports: 0 errors; closures = own + glibc¹; no build-only bytes" "python3 -I - <<'EOF'
    import json, os, sys
    a = json.load(open(os.environ['NIX_ATTRS_JSON_FILE']))
    bad = 0
    hashes = {os.path.basename(p)[:32]: p for p in a['buildOnly']}
    for pkg, outs in sorted(a['outs'].items()):
        s = json.load(open(os.path.join(outs[0], 'nix-support', 'rocky-report.json')))['summary']
        print('%s: partition %d errors, %d warnings' % (pkg, s['errors'], s['warnings']))
        bad += s['errors']
        allowed = set(a['own'][pkg]) | set(a['allowed'])
        paths = sorted({e['path'] for e in a[pkg]})
        extra = [p for p in paths if p not in allowed]
        print('%s closure: %d paths, outside own + glibc1: %s' % (pkg, len(paths), extra))
        bad += len(extra)
        for o in outs:
            for d, _dirs, files in os.walk(o):
                for f in files:
                    p = os.path.join(d, f)
                    if os.path.islink(p):
                        continue
                    data = open(p, 'rb').read()
                    for h, what in hashes.items():
                        if h.encode() in data:
                            print('%s: build-only %s in %s' % (pkg, what, p))
                            bad += 1
    sys.exit(bad != 0)
    EOF"

    check "no /usr in the test sandbox" "[ ! -e /usr/lib64 ] && [ ! -e /lib64 ]"
    check "which --version" "$whichOut/bin/which --version | grep -q 'GNU which v2.21'"
    check "xz | unxz round trip" "[ \"\$(echo hello-rocky | $xzOut/bin/xz | $xzOut/bin/unxz)\" = hello-rocky ]"
    check "gzip | gzip -d round trip" "[ \"\$(echo hello-gzip | $gzipOut/bin/gzip | $gzipOut/bin/gzip -d)\" = hello-gzip ]"
    check "PT_INTERP = glibc¹'s loader" "readelf -l $xzOut/bin/xz | grep -q \"interpreter: $glibcOut/lib64/ld-linux-x86-64.so.2\""

    rp() { readelf -d "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }
    check "xz RUNPATH = \$lib/lib64 (libc: the loader's system dir)" "[ \"\$(rp $xzOut/bin/xz)\" = $xzLib/lib64 ]"
    check "which, liblzma: no RUNPATH (libc only)" "[ -z \"\$(rp $whichOut/bin/which)\" ] && [ -z \"\$(rp $xzLib/lib64/liblzma.so.5)\" ]"
    check "no DT_RPATH anywhere" "! readelf -d $whichOut/bin/which $xzOut/bin/xz $xzLib/lib64/liblzma.so.5 $gzipOut/bin/gzip | grep -q '(RPATH)'"
    check "liblzma keeps Rocky's DT_BIND_NOW (no new-dtags DT_FLAGS)" "readelf -d $xzLib/lib64/liblzma.so.5 | grep -q '(BIND_NOW)' && ! readelf -d $xzLib/lib64/liblzma.so.5 | grep -q '(FLAGS) .*BIND_NOW'"

    check "a ccGlibc1 program against xz.dev runs" "$user/bin/lzma-user | grep -qx 'liblzma 5.6.2'"
    mkdir -p ''${outputs[out]}
    cp $TMPDIR/result.txt ''${outputs[out]}/result.txt
    [ $fail = 0 ]
  '';
}
