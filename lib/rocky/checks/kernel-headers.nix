# checks.nn-kernel-headers: the WP8 acceptance test of the relocated
# kernel-headers (rockyBoot.s1.kernel-headers, the kernel SRPM headers-only
# through mkRpmPackage; packages/kernel-headers/default.nix,
# docs/research/nix-native/experiments/wp8.md):
#   eval time   outputs (kernel-headers = out, modules_extra_matched, logs: the
#               names rule with prefixSubpackage + builtSubpackages), rpmOutputs,
#               the stage's rpm.* alias, variant resolution of a BuildRequire
#               kernel-headers, builtSubpackages validation, outputChecks
#               (siblings only: runtimeLibc = false), glibc's input
#   build time  against the official kernel-headers RPM:
#     * the partition report has 0 errors
#     * file list of <out>/include = the official RPM's /usr/include list
#       mapped to include/, minus exactly the 21 leaked tools headers
#       (docs/kernel-headers.md)
#     * every common file byte-identical (diff -r of the payload minus the
#       21 paths), file types equal, the content oracle of the FHS twin
#     * the transient RPM's metadata (nix-support/rpm/kernel-headers.json):
#       NEVR, provides, requires, obsoletes equal to the official RPM's
#     * no /nix/store string in any header; out holds include/ and
#       nix-support/ only; modules_extra_matched holds metadata only
#     * closures: every output references nothing but itself
#     * a C program compiled with -I<out>/include sees Rocky's UAPI
#       (RHEL_MAJOR 10, LINUX_VERSION 6.12, __NR_io_uring_setup)
{ bootPkgs, lib, self, stage0, fetch, ... }:
let
  pkgs = bootPkgs;
  s1 = self.stages.s1;
  kh = s1.pkgs.kernel-headers;
  recipe = import ../../../packages/kernel-headers/headers-only.nix;
  official = fetch.officialRpms."kernel-headers.x86_64";

  noDrop = { add = [ ]; addNative = [ ]; drop = [ ]; };
  tryOk = x: (builtins.tryEval (builtins.deepSeq x true)).success;
  badBuilt = self.mkRpmPackage s1 {
    srpm = "kernel";
    pname = "kernel-headers";
    overrides = kh.overrides // { builtSubpackages = [ "kernel-headers" "no-such-subpackage" ]; };
  };

  evalTests = [
    { name = "outputs: out (kernel-headers), modules_extra_matched, logs"; got = kh.outputs;
      ok = kh.outputs == [ "out" "modules_extra_matched" "logs" ]; }
    { name = "rpmOutputs = the built subpackages only"; got = kh.rpmOutputs;
      ok = kh.rpmOutputs == { kernel-headers = "out"; kernel-modules-extra-matched = "modules_extra_matched"; }; }
    { name = "plan subpackages = rpmOutputs"; got = kh.rockyPlan.subpackages;
      ok = kh.rockyPlan.subpackages == kh.rpmOutputs; }
    { name = "no debug output (debuginfo switched off)"; got = kh.rockyPlan.debugOutput;
      ok = kh.rockyPlan.debugOutput == null; }
    { name = "variant: srpm kernel, pname kernel-headers, store name kernel-headers-<v>-<r>"; got = kh.name;
      ok = kh.srpm == "kernel" && kh.pname == "kernel-headers"
        && kh.name == "kernel-headers-6.12.0-211.66.1.el10_2"; }
    { name = "stage rpm alias kernel-headers = out"; got = null;
      ok = s1.rpm."kernel-headers".outPath == kh.out.outPath; }
    { name = "no rpm alias for kernel subpackages not built (kernel-core)"; got = null;
      ok = !(s1.rpm ? "kernel-core") && !(s1.rpm ? "kernel"); }
    { name = "a BuildRequire kernel-headers resolves to the variant's out"; got = null;
      ok = map toString (s1.resolveBuildDeps "which" (noDrop // { buildRequires = [ "kernel-headers" ]; })).host
        == [ "${kh.out}" ]; }
    { name = "inputs.buildRequires rsync, python3-rpm-macros -> fallback (tool, macro trees)"; got = null;
      ok = lib.elem "rsync" kh.rockyDeps.fromFallback && lib.elem "python3-rpm-macros" kh.rockyDeps.fromFallback
        && kh.rockyDeps.macroPkgs != [ ]; }
    { name = "builtSubpackages outside the lock: eval error"; got = null;
      ok = !(tryOk badBuilt.outputs); }
    { name = "runtimeLibc = false: no runtime input, nothing allowed beyond the siblings"; got = null;
      ok = kh.rockyPlan.allowedStorePaths == [ ] && kh.rockyPlan.inputLibDirs == [ ] && kh.rockyDeps.runtime == [ ]
        && kh.drvAttrs.outputChecks.out.allowedReferences == [ "out" "modules_extra_matched" ]
        && kh.drvAttrs.outputChecks.out.allowedRequisites == [ "out" "modules_extra_matched" ]; }
    { name = "glibc's kernel-headers input is the relocated build (no interim)"; got = null;
      ok = lib.elem "${kh.out}" (map toString s1.pkgs.glibc.rockyDeps.host) && !(kh ? interim); }
    { name = "no S1 package as input (which/xz are baseTools); the same build with glibc1 = true"; got = null;
      ok = kh.rockyDeps.fromStage == [ ] && self.stages.s1Glibc1.pkgs.kernel-headers.drvPath == kh.drvPath; }
  ];
  evalFailures = lib.filter (t: !t.ok) evalTests;

  rpm = "${stage0.rpm}/usr/bin/rpm";
in
{
nn-kernel-headers = assert lib.assertMsg (evalFailures == [ ])
  ("nn-kernel-headers eval tests failed: " + lib.concatMapStringsSep "; " (t: "${t.name} (got ${builtins.toJSON t.got})") evalFailures);
pkgs.runCommand "nn-kernel-headers" {
  __structuredAttrs = true;
  nativeBuildInputs = [ pkgs.python3 pkgs.cpio pkgs.diffutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.stdenv.cc ];
  exportReferencesGraph = {
    out = [ kh.out ];
    extra = [ kh.modules_extra_matched ];
  };
  khOut = kh.out;
  khExtra = kh.modules_extra_matched;
  inherit official;
  leaked = recipe.leakedPaths;
  oracle = recipe.contentOracle;
  rpmConfigDir = "${stage0.rpm}/usr/lib/rpm";
  evalSummary = map (t: t.name) evalTests;
} ''
  set -euo pipefail
  log() { echo "$*" | tee -a $TMPDIR/result.txt; }
  fail=0
  check() { if eval "$2"; then log "PASS $1"; else log "FAIL $1"; fail=1; fi; }
  for t in "''${evalSummary[@]}"; do log "PASS (eval) $t"; done
  export RPM_CONFIGDIR=$rpmConfigDir
  q() { ${rpm} -qp --nosignature "$@" 2>/dev/null; }
  cd $TMPDIR

  # 1. partition report
  check "report: 0 errors" \
    "python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))[\"summary\"]; print(s); sys.exit(s[\"errors\"] != 0)' $khOut/nix-support/rocky-report.json"

  # 2. file lists: official /usr/include/x <-> include/x
  q -l $official | sed -n 's|^/usr/include|include|p' | LC_ALL=C sort > official.list
  ( cd $khOut && find include -mindepth 1 ) | LC_ALL=C sort > ours.list
  printf '%s\n' "''${leaked[@]}" | sed 's|^/usr/include|include|' | LC_ALL=C sort > leaked.list
  check "official RPM: every path below /usr/include" "[ \"\$(q -l $official | grep -vc '^/usr/include/')\" = 0 ]"
  LC_ALL=C comm -23 ours.list official.list > only-ours
  LC_ALL=C comm -13 ours.list official.list > only-official
  log "paths: ours $(wc -l < ours.list), official $(wc -l < official.list), only-official $(wc -l < only-official)"
  check "no path only in ours" "[ ! -s only-ours ] || { cat only-ours; false; }"
  check "paths only in official == the 21 leaked tools headers" "diff -u leaked.list only-official"
  check "1065 paths" "[ \"\$(wc -l < ours.list)\" = 1065 ]"

  # 3. contents
  mkdir x-off
  ${stage0.rpm}/usr/bin/rpm2cpio $official | (cd x-off && cpio -idm --quiet --no-absolute-filenames)
  while read -r p; do rm -rf "x-off$p"; done < <(printf '%s\n' "''${leaked[@]}")
  check "headers byte-identical to the official payload (minus the 21)" "diff -r x-off/usr/include $khOut/include"
  check "file types equal (regular / dir / symlink)" \
    "diff <(cd x-off/usr && find include -mindepth 1 -printf '%y %p\n' | LC_ALL=C sort) <(cd $khOut && find include -mindepth 1 -printf '%y %p\n' | LC_ALL=C sort)"
  mkdir -p o/usr && cp -r $khOut/include o/usr/include
  sum=$(cd o && find usr -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
  check "content oracle (FHS twin, docs/kernel-headers.md): $sum" "[ \"$sum\" = \"$oracle\" ]"
  check "no /nix/store in any header" "! grep -rl /nix/store $khOut/include"
  check "out = include/ + nix-support/ only" "[ \"\$(ls $khOut | tr '\n' ' ')\" = 'include nix-support ' ]"
  check "modules_extra_matched = metadata only" \
    "[ \"\$(cd $khExtra && find . -type f | LC_ALL=C sort | tr '\n' ' ')\" = './nix-support/rpm-name ./nix-support/rpm/kernel-modules-extra-matched.json ' ]"

  # 4. metadata of the transient RPM vs the official one
  check "metadata vs official: NEVR, provides, requires, obsoletes" "python3 -I - $khOut/nix-support/rpm/kernel-headers.json $official <<'EOF'
  import json, os, subprocess, sys
  doc = json.load(open(sys.argv[1]))
  def q(fmt):
      return subprocess.run(['${rpm}', '-qp', '--nosignature', '--qf', fmt, sys.argv[2]],
                            check=True, capture_output=True, text=True).stdout
  bad = 0
  nevr = '%s-%s-%s' % (doc['name'], doc['version'], doc['release'])
  off = q('%{NAME}-%{VERSION}-%{RELEASE}')
  print('NEVR', nevr, off); bad += nevr != off
  for kind, tag in (('provides', 'PROVIDE'), ('requires', 'REQUIRE'), ('obsoletes', 'OBSOLETE')):
      ours = sorted('%s %s %s' % (d['name'], d['flags'], d['version']) for d in doc[kind])
      theirs = sorted(l for l in q('[%%{%sNAME} %%{%sFLAGS} %%{%sVERSION}\\\\n]' % (tag, tag, tag)).splitlines() if l)
      print(kind, ours == theirs, len(ours))
      if ours != theirs:
          print('  ours  ', ours); print('  theirs', theirs); bad += 1
  sys.exit(bad != 0)
  EOF"

  # 5. closures
  check "closures: each output references only itself" "python3 -I - <<'EOF'
  import json, os, sys
  a = json.load(open(os.environ['NIX_ATTRS_JSON_FILE']))
  bad = 0
  for k, own in (('out', a['khOut']), ('extra', a['khExtra'])):
      paths = sorted({e['path'] for e in a[k]})
      print(k, paths)
      bad += paths != [own]
  sys.exit(bad != 0)
  EOF"

  # 6. a consumer: nixpkgs cc with -I<out>/include ahead of its own headers
  cat > t.c <<'EOF'
  #include <linux/version.h>
  #include <asm/unistd.h>
  #include <stdio.h>
  int main(void) {
    printf("%d %d %d %d\n", RHEL_MAJOR, LINUX_VERSION_MAJOR, LINUX_VERSION_PATCHLEVEL, __NR_io_uring_setup);
    return 0;
  }
  EOF
  check "compiled against <out>/include: RHEL 10, Linux 6.12, io_uring_setup 425" \
    "cc -I$khOut/include -o t t.c && [ \"\$(./t)\" = '10 6 12 425' ]"
  check "the headers come from <out>/include" "cc -I$khOut/include -E -H t.c 2>&1 >/dev/null | grep -q \"$khOut/include/linux/version.h\""

  mkdir -p ''${outputs[out]}
  cp $TMPDIR/result.txt ''${outputs[out]}/result.txt
  [ $fail = 0 ]
'';
}
