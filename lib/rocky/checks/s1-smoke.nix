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
#     * zlib-ng, gzip: 0 errors, closures; gzip's ELF round trip; the
#       #!/usr/bin/sh scripts are exactly the S1 fhsAllowlist exception (they
#       do not run here: no /usr/bin/sh); find_package(ZLIB CONFIG) works
#       against compat_devel (cmake-unrequired -> compat_static)
#   eval time (WP6 review)
#     * direct references (§7.1): xz on glibc¹ (nn.stages.s1Glibc1) may
#       reference only glibc's out (allowedStorePaths, allowedReferences),
#       not glibc.dev/static/langpacks; inputLibDirs = glibc.out's only
#     * BuildRequires the lock could not resolve fail evaluation unless named
#     * purity wiring: every purity violation of the S1 packages comes from
#       what S1 declares as nixpkgs/stage0 (the stdenv, its builder shell, the
#       cc wrapper descent, the fallback entries); none from mkRpmPackage's or
#       mkStage's own machinery (partition tool, rpm, rpm config, fhsBins,
#       libc, outputChecks)
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  s1 = self.stages.s1;
  inherit (s1.pkgs) which xz gzip;
  zlib = s1.pkgs.zlib-ng;
  g1 = self.stages.s1Glibc1;
  xzG1 = g1.pkgs.xz;
  glibc1 = g1.pkgs.glibc;

  # purity: violations not explained by S1's declared nixpkgs/stage0 parts
  fallbackKeys = lib.concatMap (f:
    map self.purity.drvPathOf (lib.filter lib.isDerivation (f.native or [ ] ++ f.host or [ ] ++ f.view or [ ]))
    ++ lib.concatMap (d: lib.attrNames (builtins.getContext d)) (f.macroDirs or [ ]))
    (lib.attrValues s1.fallback);
  declared = v: lib.elem v.key fallbackKeys
    || builtins.match "[.](builder|stdenv > .*|nativeBuildInputs[[]0[]] > .*)" v.chain != null;
  unexplained = p: lib.filter (v: !(declared v)) (self.purity.violations s1 p);
  noDrop = { add = [ ]; addNative = [ ]; drop = [ ]; };
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
    { name = "xz on glibc1: allowedStorePaths = glibc.out only"; got = xzG1.rockyPlan.allowedStorePaths;
      ok = xzG1.rockyPlan.allowedStorePaths == [ "${glibc1.out}" ]; }
    { name = "xz on glibc1: inputLibDirs = glibc.out's"; got = xzG1.rockyPlan.inputLibDirs;
      ok = xzG1.rockyPlan.inputLibDirs == [ "${glibc1.out}/lib64" "${glibc1.out}/lib" ]; }
    { name = "xz on glibc1: allowedReferences = siblings + glibc.out"; got = null;
      ok = map toString xzG1.drvAttrs.outputChecks.out.allowedReferences
        == [ "out" "dev" "lib" "lzma_compat" "static" "${glibc1.out}" ]; }
    { name = "xz on glibc1: glibc.dev only in the closure bound"; got = null;
      ok = !(lib.elem "${glibc1.dev}" (map toString xzG1.drvAttrs.outputChecks.out.allowedReferences))
        && lib.elem "${glibc1.dev}" (map toString xzG1.drvAttrs.outputChecks.out.allowedRequisites); }
    { name = "companions: xz dev -> out lib, zlib-ng compat_devel -> compat"; got = null;
      ok = xz.rockyCompanions.dev == [ "out" "lib" ] && zlib.rockyCompanions.compat_devel == [ "compat" ]; }
    { name = "unresolved BuildRequires (zlib-ng cmake(GTest)) not named: eval error"; got = null;
      ok = !(builtins.tryEval (builtins.deepSeq (s1.resolveBuildDeps "zlib-ng" noDrop).native null)).success
        && (builtins.tryEval (builtins.deepSeq (s1.resolveBuildDeps "zlib-ng" (noDrop // { drop = [ "cmake(GTest)" ]; })).unresolved null)).success; }
    { name = "S1 fhsAllowlist = #!/usr/bin/sh only"; got = gzip.rockyPlan.fhsAllowlist;
      ok = lib.attrNames gzip.rockyPlan.fhsAllowlist == [ "#!/usr/bin/sh" ]; }
  ] ++ map (n: { name = "purity: no machinery violations (${n})"; got = map (v: v.chain) (unexplained s1.pkgs.${n});
                 ok = unexplained s1.pkgs.${n} == [ ]; }) [ "which" "xz" "zlib-ng" "gzip" ];
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
    zlib = pkgOutputs zlib;
    gzip = pkgOutputs gzip;
  };
  own = {
    which = map toString (pkgOutputs which);
    xz = map toString (pkgOutputs xz);
    zlib = map toString (pkgOutputs zlib);
    gzip = map toString (pkgOutputs gzip);
  };
  gzipOut = gzip.out;
  zlibOut = zlib.out;
  zlibCompatDevel = zlib.compat_devel;
  zlibCompatStatic = zlib.compat_static;
  cmake = "${pkgs.cmake}/bin/cmake";
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
  for r in $which_out/nix-support/rocky-report.json $xzOut/nix-support/rocky-report.json \
           $zlibOut/nix-support/rocky-report.json $gzipOut/nix-support/rocky-report.json; do
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
  for pkg in ('which', 'xz', 'zlib', 'gzip'):
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

  # 6. gzip: the ELF program runs; the /usr/bin/sh scripts are the named
  # S1 exception and do not run without /usr/bin/sh
  check "gzip | gzip -d round trip (ELF)" "[ \"\$(echo hello-gzip | $gzipOut/bin/gzip | $gzipOut/bin/gzip -d)\" = hello-gzip ]"
  check "gunzip is a #!/usr/bin/sh script (S1 fhsAllowlist)" "[ \"\$(head -1 $gzipOut/bin/gunzip)\" = '#!/usr/bin/sh' ]"
  check "gunzip does not run here (no /usr/bin/sh)" "[ ! -e /usr/bin/sh ] && ! $gzipOut/bin/gunzip --version >/dev/null 2>&1"
  check "FHS shebangs of gzip/xz bin: #!/usr/bin/sh only" "[ -z \"\$(for f in $gzipOut/bin/* $xzOut/bin/*; do head -c2 \$f | grep -q '#!' && head -1 \$f; done | grep -E '^#! ?/(usr|bin|sbin)/' | grep -v -x -e '#!/usr/bin/sh' -e '#!/bin/sh')\" ]"

  # 7. zlib-ng: compat_devel's CMake export names compat_static's libz.a
  check "ZLIB-release.cmake -> compat_static" "grep -q $zlibCompatStatic/lib64/libz.a $zlibCompatDevel/lib64/cmake/ZLIB/ZLIB-release.cmake"
  mkdir -p $TMPDIR/cm/src
  printf 'cmake_minimum_required(VERSION 3.20)\nproject(t NONE)\nfind_package(ZLIB CONFIG REQUIRED)\n' > $TMPDIR/cm/src/CMakeLists.txt
  check "find_package(ZLIB CONFIG) against compat_devel" "$cmake -S $TMPDIR/cm/src -B $TMPDIR/cm/b -DZLIB_DIR=$zlibCompatDevel/lib64/cmake/ZLIB > $TMPDIR/cm/log 2>&1 || { cat $TMPDIR/cm/log; false; }"

  mkdir -p ''${outputs[out]}
  cp $TMPDIR/result.txt ''${outputs[out]}/result.txt
  [ $fail = 0 ]
'';
}
