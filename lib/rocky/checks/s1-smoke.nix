# checks.nn-s1-smoke: the WP6 acceptance test of mkRpmPackage + mkStage on
# stage S1 (docs/research/nix-native/experiments/wp6.md):
#   eval time   outputs of rockyBoot.s1.{which,xz} = names.outputsFor over
#               subpackages.json (out first, debug, logs); rpmOutputs /
#               shippedRpmOutputs / unshipped; nn.stages.s1.rpm aliases
#   build time  in a plain sandbox (no /usr, no shim):
#     * every partition report has 0 errors
#     * which and xz run from the store; xz/unxz/lzcat round trips; xz finds
#       liblzma through its own RUNPATH ($lib/lib64), libc through the S1
#       exception (the stage0 libc tree)
#     * RUNPATHs exactly as recomputed (no self rpath, no gcc -L dir)
#     * closures: own outputs + the named S1 exception only
#     * composability: a program built by the S1 cc with buildInputs =
#       [ xz.dev ] (dev propagates lib) links and runs
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  s1 = self.stages.s1;
  inherit (s1.pkgs) which xz;
  exceptions = [ s1.stage0LibcTree ];
  nonDebug = lib.filterAttrs (n: _: !(self.names.isDebugName n));

  evalTests = [
    { name = "which outputs"; ok = which.outputs == [ "out" "debug" "logs" ]; got = which.outputs; }
    { name = "xz outputs"; ok = xz.outputs == [ "out" "dev" "lib" "lzma_compat" "static" "debug" "logs" ]; got = xz.outputs; }
    { name = "xz outputs = names.outputsForSrpm"; ok = xz.outputs == (self.names.outputsForSrpm { srpm = "xz"; }).outputs; got = null; }
    { name = "xz rpmOutputs"; got = nonDebug xz.rpmOutputs;
      ok = nonDebug xz.rpmOutputs == { xz = "out"; xz-devel = "dev"; xz-libs = "lib"; xz-lzma-compat = "lzma_compat"; xz-static = "static"; }; }
    { name = "xz unshipped"; ok = xz.unshipped == { xz-static = "static"; }; got = xz.unshipped; }
    { name = "xz shippedRpmOutputs"; got = nonDebug xz.shippedRpmOutputs;
      ok = nonDebug xz.shippedRpmOutputs == { xz = "out"; xz-devel = "dev"; xz-libs = "lib"; xz-lzma-compat = "lzma_compat"; }; }
    { name = "stage rpm alias xz-libs"; ok = s1.rpm."xz-libs".outPath == xz.lib.outPath; got = null; }
    { name = "no rpm alias for unshipped xz-static"; ok = !(s1.rpm ? "xz-static"); got = null; }
    { name = "rockyStage"; ok = xz.rockyStage == "s1" && which.rockyStage == "s1"; got = xz.rockyStage; }
    { name = "plan subpackages"; ok = xz.rockyPlan.subpackages == nonDebug xz.rpmOutputs; got = null; }
  ];
  evalFailures = lib.filter (t: !t.ok) evalTests;

  # composability: the S1 cc + xz.dev as an ordinary nixpkgs-style input
  lzmaUser = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-s1-smoke-lzma-user";
    nativeBuildInputs = [ self.cc.stage0 ];
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

  pkgOutputs = p: map (o: p.${o}) (lib.remove "logs" p.outputs);
in
{
nn-s1-smoke = assert lib.assertMsg (evalFailures == [ ])
  ("nn-s1-smoke eval tests failed: " + lib.concatMapStringsSep "; " (t: "${t.name} (got ${builtins.toJSON t.got})") evalFailures);
pkgs.runCommand "nn-s1-smoke" {
  __structuredAttrs = true;
  nativeBuildInputs = [ pkgs.python3 pkgs.binutils ];
  exportReferencesGraph = {
    which = pkgOutputs which;
    xz = pkgOutputs xz;
  };
  own = {
    which = map toString (pkgOutputs which);
    xz = map toString (pkgOutputs xz);
  };
  allowed = map toString exceptions;
  whichOut = which.out;
  xzOut = xz.out;
  xzLib = xz.lib;
  xzDev = xz.dev;
  xzCompat = xz.lzma_compat;
  libcTree = s1.stage0LibcTree;
  user = lzmaUser;
  evalSummary = map (t: t.name) evalTests;
} ''
  set -euo pipefail
  log() { echo "$*" | tee -a $TMPDIR/result.txt; }
  fail=0
  check() { if eval "$2"; then log "PASS $1"; else log "FAIL $1"; fail=1; fi; }
  for t in "''${evalSummary[@]}"; do log "PASS (eval) $t"; done

  which_out=$whichOut

  # 1. partition reports: no errors
  for r in $which_out/nix-support/rocky-report.json $xzOut/nix-support/rocky-report.json; do
    check "report $(basename $(dirname $(dirname $r))): 0 errors" \
      "python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))[\"summary\"]; print(s); sys.exit(s[\"errors\"] != 0)' $r"
  done

  # 2. run from the store, outside any shim (this sandbox has no /usr)
  check "no /usr in the test sandbox" "[ ! -e /usr/lib64 ] && [ ! -e /lib64 ]"
  check "which --version" "$which_out/bin/which --version | grep -q 'GNU which v2.21'"
  check "which finds itself" "[ \"\$(PATH=$which_out/bin $which_out/bin/which which)\" = $which_out/bin/which ]"
  check "xz --version" "$xzOut/bin/xz --version | grep -qx 'liblzma 5.6.2'"
  check "xz | unxz round trip" "[ \"\$(echo hello-rocky | $xzOut/bin/xz | $xzOut/bin/unxz)\" = hello-rocky ]"
  check "lzma_compat lzcat (cross-output symlink)" "[ \"\$(echo hello-lzma | $xzOut/bin/xz --format=lzma | $xzCompat/bin/lzcat)\" = hello-lzma ]"
  check "xzdec" "[ \"\$(echo hi | $xzOut/bin/xz | $xzOut/bin/xzdec)\" = hi ]"

  # 3. RUNPATHs as Phase E recomputed them
  rp() { readelf -d "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }
  check "xz RUNPATH = \$lib/lib64:<libc>/lib64" "[ \"\$(rp $xzOut/bin/xz)\" = $xzLib/lib64:$libcTree/lib64 ]"
  check "liblzma RUNPATH = <libc>/lib64" "[ \"\$(rp $xzLib/lib64/liblzma.so.5)\" = $libcTree/lib64 ]"
  check "which RUNPATH = <libc>/lib64" "[ \"\$(rp $which_out/bin/which)\" = $libcTree/lib64 ]"
  check "no DT_RPATH" "! readelf -d $xzOut/bin/xz $xzLib/lib64/liblzma.so.5 $which_out/bin/which | grep -q '(RPATH)'"
  check "PT_INTERP = the S1 libc loader" "readelf -l $xzOut/bin/xz | grep -q \"interpreter: $libcTree/lib64/ld-linux-x86-64.so.2\""
  check "dev liblzma.so -> lib" "[ \"\$(readlink -f $xzDev/lib64/liblzma.so)\" = \"\$(readlink -f $xzLib/lib64/liblzma.so.5)\" ]"
  check "dev propagates lib" "grep -q $xzLib $xzDev/nix-support/propagated-build-inputs"
  check "liblzma.pc libdir/includedir in dev" "grep -qx libdir=$xzDev/lib64 $xzDev/lib64/pkgconfig/liblzma.pc && grep -qx includedir=$xzDev/include $xzDev/lib64/pkgconfig/liblzma.pc"

  # 4. closures: own outputs + named S1 exceptions only
  check "closures = own outputs + S1 exceptions" "python3 -I - <<'EOF'
  import json, os, sys
  a = json.load(open(os.environ['NIX_ATTRS_JSON_FILE']))
  bad = 0
  for pkg in ('which', 'xz'):
      allowed = set(a['own'][pkg]) | set(a['allowed'])
      paths = sorted({e['path'] for e in a[pkg]})
      extra = [p for p in paths if p not in allowed]
      print('%s closure: %d paths, %d outside own outputs + exceptions %s' % (pkg, len(paths), len(extra), extra))
      bad += len(extra)
  sys.exit(bad != 0)
  EOF"

  # 5. composability: built by the S1 cc against xz.dev, runs
  check "program built against xz.dev runs" "$user/bin/lzma-user | grep -qx 'liblzma 5.6.2'"
  check "its RUNPATH names xz's lib output" "rp $user/bin/lzma-user | tr : '\n' | grep -qx $xzLib/lib64"

  mkdir -p ''${outputs[out]}
  cp $TMPDIR/result.txt ''${outputs[out]}/result.txt
  [ $fail = 0 ]
'';
}
