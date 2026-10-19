# checks.nn-glibc-smoke: the M1 acceptance test of rockyBoot.s1.glibc
# (docs/nix-native-design.md §0.4.1, §12 WP7; docs/research/nix-native/
# experiments/wp7.md).
#   eval time
#     * outputs = names.outputsFor over subpackages.json: 224 subpackages,
#       glibc32 merged into out (223) + debug + logs = 225, out first
#     * the §11.5 recipe reached the derivation: NIX_NO_SELF_RPATH and
#       NIX_DONT_SET_RPATH in the structured env, user-defined-trusted-dirs
#       NOT there but on rpmbuild's command line (env 'k=v'), pointing at
#       libgccForGlibc's lib64 and lib; the three Nix patches; glibc.site
#     * outputChecks: every managed output may reference exactly its siblings
#       and libgccForGlibc (nothing else: no stage0 tree, no kernel-headers,
#       no nixpkgs path); lateBind declared, S1 exceptions named
#   build time, in a plain sandbox (no /usr, no /lib64, no shim)
#     * the partition report has 0 errors and no cycle
#     * closure of every output (debug included) = sibling outputs +
#       libgccForGlibc; the output reference graph is acyclic; closure sizes
#     * no foreign store path anywhere in any output: every file (symlink
#       targets, ELF sections decoded -- compressed debug sections and
#       .gnu_debugdata --, ar members, gzip/xz/bzip2/zstd files) holds only
#       glibc's own and libgccForGlibc's hashes, and no 8-byte piece of the
#       hash of a build input (stage0 trees, the gcc/binutils copies, the
#       nixpkgs tools, the rpm config, kernel-headers)
#     * programs compiled with nn.cc.wrap { libc = rockyBoot.s1.glibc } run
#       here: hello (the plain wrapper); with the S1 glibc¹ toolchain
#       (nn.stages.s1.ccGlibc1: + kernel-headers as include root) errno/linux
#       headers, pthread_cancel (dlopens libgcc_s.so.1 from the trusted dir),
#       locales via LOCPATH and (P2) LOCALE_ARCHIVE, -static, -m32, C++
#     * ld.so --list-diagnostics: prefix and rtld in out, system dirs =
#       out/lib64, libgccForGlibc/lib64, libgccForGlibc/lib
#     * the Nix patches act: ld.so.cache under out/etc (P1; the loader's
#       sysconfdir reads out/etc, libc keeps /etc/localtime etc.), LOCALE_ARCHIVE in
#       libc (P2), /etc/ld-nix.so.preload (P3); getconf, iconv (default gconv
#       dir), memusagestat's NEEDED left unresolved (S1 allowUnresolvedNeeded)
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  s1 = self.stages.s1;
  glibc = s1.pkgs.glibc;
  kh = s1.pkgs.kernel-headers;
  lg = s1.libgccForGlibc;
  managed = lib.filter (o: o != "debug" && o != "logs") glibc.outputs;
  outPaths = map (o: glibc.${o}) (lib.remove "logs" glibc.outputs);
  sub = self.names.subpackagesFor "glibc";
  merges = glibc.overrides.mergeOutputs;
  expectedCount = lib.length sub.names
    - lib.foldl' (n: g: n + lib.length g - 1) 0 merges + 2;   # + debug + logs

  # the literal acceptance wrapper and the S1 glibc¹ toolchain (+ kernel headers)
  ccPlain = self.cc.wrap { libc = glibc; name = "rocky-s1-glibc1-plain"; };
  ccFull = s1.ccGlibc1;

  # every build input whose hash must not appear (full or in pieces)
  wrapperOf = s1.ccFor "glibc";
  foreign = lib.unique (lib.filter (p: p != null) ([
      wrapperOf wrapperOf.cc wrapperOf.bintools (wrapperOf.bintools.bintools or null)
      s1.stage0LibcTree s1.glibcBuildDeps kh s1.rpmConfig s1.rpmPkg s1.toolShim
      s1.patchelf s1.python3 s1.bsdtar
    ] ++ s1.baseTools ++ glibc.rockyDeps.native ++ glibc.rockyDeps.host ++ glibc.rockyDeps.view));

  str = map toString;
  refsOut = str glibc.drvAttrs.outputChecks.out.allowedReferences;
  evalTests = [
    { name = "output count = subpackages - merges + debug + logs (${toString expectedCount})";
      ok = lib.length glibc.outputs == expectedCount && expectedCount == 225; got = lib.length glibc.outputs; }
    { name = "outputs = names.outputsForSrpm"; got = null;
      ok = glibc.outputs == (self.names.outputsForSrpm { srpm = "glibc"; mergeOutputs = merges; }).outputs; }
    { name = "out first, debug and logs last"; got = null;
      ok = lib.head glibc.outputs == "out" && lib.take 2 (lib.reverseList glibc.outputs) == [ "logs" "debug" ]; }
    { name = "glibc32 merged into out"; ok = glibc.rpmOutputs.glibc32 == "out"; got = glibc.rpmOutputs.glibc32; }
    { name = "unshipped: glibc32, sysroot, compat-libpthread-nonshared"; got = glibc.unshipped;
      ok = lib.attrNames glibc.unshipped == [ "compat-libpthread-nonshared" "glibc32" "sysroot-x86_64-el10-glibc" ]; }
    { name = "NIX_NO_SELF_RPATH / NIX_DONT_SET_RPATH are derivation attributes"; got = null;
      ok = glibc.drvAttrs.env.NIX_NO_SELF_RPATH == "1" && glibc.drvAttrs.env.NIX_DONT_SET_RPATH == "1"; }
    { name = "user-defined-trusted-dirs: rpmbuild command line only"; got = glibc.drvAttrs.rockyRpmbuildEnv;
      ok = !(glibc.drvAttrs.env ? "user-defined-trusted-dirs")
        && glibc.drvAttrs.rockyRpmbuildEnv == { "user-defined-trusted-dirs" = "${lg}/lib64:${lg}/lib"; }; }
    { name = "nixPatches P1 P2 P3"; got = map baseNameOf glibc.drvAttrs.rockyNixPatches;
      ok = map (p: lib.removePrefix "-" (lib.substring 32 999 (baseNameOf p))) glibc.drvAttrs.rockyNixPatches
        == [ "ld-so-cache.patch" "locale-archive.patch" "ld-preload.patch" ]; }
    { name = "CONFIG_SITE = config.site + glibc.site"; got = glibc.drvAttrs.rockyConfigSite;
      ok = lib.length (lib.splitString " " glibc.drvAttrs.rockyConfigSite) == 2
        && lib.hasSuffix "-glibc.site" glibc.drvAttrs.rockyConfigSite; }
    { name = "allowedReferences = siblings + libgccForGlibc"; got = lib.subtractLists managed refsOut;
      ok = refsOut == managed ++ [ "${lg}" ]; }
    { name = "allowedRequisites = siblings + libgccForGlibc"; got = null;
      ok = str glibc.drvAttrs.outputChecks.out.allowedRequisites == managed ++ [ "${lg}" ]; }
    { name = "plan allowedStorePaths = libgccForGlibc; no input lib dirs"; got = glibc.rockyPlan.allowedStorePaths;
      ok = glibc.rockyPlan.allowedStorePaths == [ "${lg}" ] && glibc.rockyPlan.inputLibDirs == [ ]; }
    { name = "kernel-headers is a build input, not a runtime input"; got = null;
      ok = lib.elem "${kh}" (str glibc.drvAttrs.rockyViewInputs) && !(lib.elem "${kh}" refsOut); }
    { name = "systemLibDirs = own lib64, lib"; ok = glibc.rockyPlan.systemLibDirs == [ "@out@/lib64" "@out@/lib" ]; got = null; }
    { name = "lateBind declared (common utils nss_db benchtests), lateReferrers"; got = lib.attrNames glibc.rockyPlan.lateBind;
      ok = lib.attrNames glibc.rockyPlan.lateBind == [ "benchtests" "common" "nss_db" "utils" ]
        && glibc.rockyPlan.lateReferrers.nss_db == [ "nss_devel" ]; }
    { name = "S1 exceptions named: allowUnresolvedNeeded, fhsAllowlist"; got = glibc.rockyPlan.allowUnresolvedNeeded;
      ok = glibc.rockyPlan.allowUnresolvedNeeded == [ "libgd.so.3" "libpng16.so.16" "libz.so.1" "libselinux.so.1" ]
        && lib.attrNames glibc.rockyPlan.fhsAllowlist == [ "#!/usr/bin/bash" "#!/usr/bin/python3" "#!/usr/bin/sh" ]; }
    { name = "rockyStage s1"; ok = glibc.rockyStage == "s1"; got = glibc.rockyStage; }
  ];
  evalFailures = lib.filter (t: !t.ok) evalTests;

  # ---- programs, built against rockyBoot.s1.glibc ---------------------------
  srcs = pkgs.runCommand "nn-glibc-smoke-src" { } ''
    mkdir -p $out
    cat > $out/hello.c <<'EOF'
    #include <stdio.h>
    int main(void) { puts("hello from rockyBoot.s1.glibc"); return 0; }
    EOF
    cat > $out/linux.c <<'EOF'
    #include <errno.h>
    #include <signal.h>
    #include <string.h>
    #include <stdio.h>
    #include <sys/ioctl.h>
    #include <linux/version.h>
    #include <gnu/libc-version.h>
    int main(void) {
      printf("glibc %s linux-headers %d.%d ENOENT=%s SIGTERM=%d TIOCGWINSZ=%#x\n",
             gnu_get_libc_version(), LINUX_VERSION_CODE >> 16, (LINUX_VERSION_CODE >> 8) & 255,
             strerror(ENOENT), SIGTERM, (unsigned) TIOCGWINSZ);
      return 0;
    }
    EOF
    cat > $out/cancel.c <<'EOF'
    #include <pthread.h>
    #include <stdio.h>
    #include <unistd.h>
    static void *t(void *a) { (void) a; for (;;) pause(); return NULL; }
    int main(void) {
      pthread_t th; void *r;
      if (pthread_create(&th, NULL, t, NULL)) return 2;
      usleep(10000);
      if (pthread_cancel(th)) return 3;
      if (pthread_join(th, &r)) return 4;
      puts(r == PTHREAD_CANCELED ? "cancelled" : "not cancelled");
      return r == PTHREAD_CANCELED ? 0 : 1;
    }
    EOF
    cat > $out/locale.c <<'EOF'
    #include <langinfo.h>
    #include <locale.h>
    #include <stdio.h>
    int main(void) {
      if (!setlocale(LC_ALL, "")) { puts("setlocale failed"); return 1; }
      printf("%s %s\n", nl_langinfo(CODESET), nl_langinfo(DAY_1));
      return 0;
    }
    EOF
    cat > $out/hello.cc <<'EOF'
    #include <iostream>
    #include <string>
    int main() { std::string s = "hello c++"; std::cout << s << std::endl; return 0; }
    EOF
  '';

  progsPlain = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-glibc-smoke-plain";
    nativeBuildInputs = [ ccPlain ];
    strictDeps = true;
    dontUnpack = true;
    buildPhase = "gcc -O2 -o hello ${srcs}/hello.c";
    installPhase = "mkdir -p $out/bin; cp hello $out/bin/";
  };

  progs = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-glibc-smoke-progs";
    nativeBuildInputs = [ ccFull ];
    strictDeps = true;
    dontUnpack = true;
    buildPhase = ''
      set -x
      gcc -O2 -o linux ${srcs}/linux.c
      gcc -O2 -pthread -o cancel ${srcs}/cancel.c
      gcc -O2 -o locale ${srcs}/locale.c
      gcc -O2 -static -L${glibc.static}/lib64 -o hello-static ${srcs}/hello.c
      gcc -O2 -m32 -o hello-m32 ${srcs}/hello.c
      g++ -O2 -o hello-cxx ${srcs}/hello.cc
      set +x
    '';
    installPhase = "mkdir -p $out/bin; cp linux cancel locale hello-static hello-m32 hello-cxx $out/bin/";
  };

  # store hashes allowed in any glibc output
  allowedRoots = str outPaths ++ [ "${lg}" ];
in
{
nn-glibc-smoke = assert lib.assertMsg (evalFailures == [ ])
  ("nn-glibc-smoke eval tests failed: " + lib.concatMapStringsSep "; " (t: "${t.name} (got ${builtins.toJSON t.got})") evalFailures);
pkgs.runCommand "nn-glibc-smoke" {
  __structuredAttrs = true;
  nativeBuildInputs = [ pkgs.python3 pkgs.binutils pkgs.zstd ];
  # one closure per output (debug included): checked one by one
  exportReferencesGraph = lib.genAttrs (lib.remove "logs" glibc.outputs) (o: [ glibc.${o} ]);
  own = lib.genAttrs (lib.remove "logs" glibc.outputs) (o: "${glibc.${o}}");
  inherit allowedRoots;
  libgcc = "${lg}";
  foreign = str foreign;
  storescan = "${self.cc.storescan}";
  G = "${glibc.out}";
  commonOut = "${glibc.common}";
  utilsOut = "${glibc.utils}";
  langpackDeOut = "${glibc.langpack_de}";
  allLangpacksOut = "${glibc.all_langpacks}";
  logsOut = "${glibc.logs}";
  plain = progsPlain;
  progs = progs;
  evalSummary = map (t: t.name) evalTests;
} ''
  set -euo pipefail
  log() { echo "$*" | tee -a $TMPDIR/result.txt; }
  fail=0
  check() { if eval "$2"; then log "PASS $1"; else log "FAIL $1"; fail=1; fi; }
  for t in "''${evalSummary[@]}"; do log "PASS (eval) $t"; done
  G=$G

  # 1. partition report
  check "partition report: 0 errors, no cycle" "python3 -I - $G/nix-support/rocky-report.json <<'EOF'
  import json, sys
  r = json.load(open(sys.argv[1]))
  s = r['summary']
  print('summary', s)
  cyc = [f for f in r.get('findings', []) if f.get('code') == 'cycle']
  sys.exit(s['errors'] != 0 or bool(cyc))
  EOF"

  # 2. closures, reference graph, sizes
  check "closure of every output = siblings + libgccForGlibc; acyclic" "python3 -I - > $TMPDIR/closures.txt <<'EOF'
  import json, os, sys
  a = json.load(open(os.environ['NIX_ATTRS_JSON_FILE']))
  own = a['own']; byPath = {p: o for o, p in own.items()}
  allowed = set(own.values()) | {a['libgcc']}
  bad = 0; refs = {}; size = {}
  for o, p in sorted(own.items()):
      graph = a[o]
      paths = {e['path'] for e in graph}
      for e in graph:
          size[e['path']] = e['narSize']
          refs[e['path']] = [r for r in e['references'] if r != e['path']]
      extra = sorted(paths - allowed)
      if extra:
          print('FAIL %s: closure has %s' % (o, extra)); bad += 1
  # cycles among outputs (Nix forbids them; checked independently)
  state = {}
  def dfs(n, stack):
      state[n] = 1
      for m in refs.get(n, []):
          if state.get(m) == 1:
              print('FAIL cycle', [byPath.get(x, x) for x in stack + [m]]); return True
          if m not in state and dfs(m, stack + [m]): return True
      state[n] = 2
      return False
  cyc = any(dfs(p, [p]) for p in sorted(refs) if p not in state)
  def closure(p):
      seen, todo = set(), [p]
      while todo:
          x = todo.pop()
          if x in seen: continue
          seen.add(x); todo += refs.get(x, [])
      return seen
  mib = lambda n: '%.1f MiB' % (n / 1048576)
  total = sum(size[p] for p in own.values())
  print('outputs: %d, total NAR size (debug included): %s, libgccForGlibc %s' % (len(own), mib(total), mib(size.get(a['libgcc'], 0))))
  for o in ('out', 'dev', 'common', 'utils', 'static', 'devel', 'langpack_de', 'all_langpacks', 'minimal_langpack', 'debug'):
      if o in own:
          c = closure(own[o])
          print('closure %-18s %3d paths %10s (own NAR %s)' % (o, len(c), mib(sum(size[x] for x in c)), mib(size[own[o]])))
  refd = {byPath[r] for p in own.values() for r in refs.get(p, []) if r in byPath}
  print('outputs referenced by a sibling:', len(refd), '; outputs referencing libgccForGlibc:',
        sorted(byPath[p] for p in own.values() if a['libgcc'] in refs.get(p, [])))
  sys.exit(bad != 0 or cyc)
  EOF
  cat $TMPDIR/closures.txt"
  cat $TMPDIR/closures.txt | tee -a $TMPDIR/result.txt

  # 3. no foreign store path, also nested/compressed/pieced
  check "no foreign store path or input-hash piece in any output (nested, compressed)" "python3 -I - > $TMPDIR/scan.txt 2>&1 <<'EOF'
  import bz2, gzip, json, lzma, os, shutil, subprocess, sys, importlib.util
  a = json.load(open(os.environ['NIX_ATTRS_JSON_FILE']))
  spec = importlib.util.spec_from_file_location('storescan', a['storescan'])
  ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
  selfs = {ss.hash_of(p) for p in a['allowedRoots']}
  inputs = {ss.hash_of(p): p for p in a['foreign']}
  sc = ss.Scanner(selfs, inputs, False)
  def decompress(d):
      if d[:2] == b'\x1f\x8b': return gzip.decompress(d)
      if d[:6] == b'\xfd7zXZ\x00': return lzma.decompress(d)
      if d[:3] == b'BZh': return bz2.decompress(d)
      if d[:4] == b'\x28\xb5\x2f\xfd':
          return subprocess.run(['zstd', '-dc'], input=d, capture_output=True, check=True).stdout
      return None
  stats = {'files': 0, 'links': 0, 'elf': 0, 'ar-members': 0, 'decompressed': 0}
  def scan(rel, d, depth=0):
      if d[:4] == b'\x7fELF':
          stats['elf'] += 1
          if sc.scan_elf(rel, d): return
      if d[:8] == b'!<arch>\n' and depth < 2:
          i = 8
          while i + 60 <= len(d):
              hdr = d[i:i + 60]; n = int(hdr[48:58].decode().strip() or 0)
              body = d[i + 60:i + 60 + n]; stats['ar-members'] += 1
              scan(rel + '(' + hdr[:16].decode('latin-1').strip() + ')', body, depth + 1)
              i += 60 + n + (n & 1)
          return
      try:
          inner = decompress(d) if depth < 2 else None
      except Exception as e:
          inner = None
      if inner is not None:
          stats['decompressed'] += 1
          sc.scan_blob(rel, '-', d)
          scan(rel + '!', inner, depth + 1); return
      sc.scan_blob(rel, '-', d)
  for o, root in sorted(list(a['own'].items()) + [('logs', a['logsOut'])]):
      for dp, dns, fns in os.walk(root):
          dns.sort()
          for fn in sorted(fns) + [x for x in dns if os.path.islink(os.path.join(dp, x))]:
              p = os.path.join(dp, fn); rel = o + ':' + os.path.relpath(p, root)
              if os.path.islink(p):
                  stats['links'] += 1
                  sc.scan_blob(rel, 'symlink', os.readlink(p).encode()); continue
              if not os.path.isfile(p): continue
              stats['files'] += 1
              scan(rel, open(p, 'rb').read())
  for f in sc.findings[:100]: print('\t'.join(f))
  print('scanned', stats, 'inputs', len(sc.inputs), 'findings', len(sc.findings))
  sys.exit(1 if sc.findings else 0)
  EOF"
  tail -3 $TMPDIR/scan.txt | tee -a $TMPDIR/result.txt

  # 4. programs, run here (no /usr, no /lib64)
  rp() { readelf -d "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }
  check "no /usr and no /lib64 in the test sandbox" "[ ! -e /usr/lib64 ] && [ ! -e /usr/lib ] && [ ! -e /lib64 ] && [ ! -e /usr/include ]"
  check "hello (nn.cc.wrap { libc = glibc }) runs" "$plain/bin/hello | grep -qx 'hello from rockyBoot.s1.glibc'"
  check "hello PT_INTERP = glibc out loader" "readelf -l $plain/bin/hello | grep -q \"interpreter: $G/lib64/ld-linux-x86-64.so.2\""
  check "no DT_RPATH in hello" "! readelf -d $plain/bin/hello | grep -q '(RPATH)'"
  check "linux headers + errno strings" "$progs/bin/linux | tee -a $TMPDIR/result.txt | grep -q '^glibc 2.39 linux-headers 6.12 ENOENT=No such file or directory SIGTERM=15 TIOCGWINSZ=0x5413$'"
  check "pthread_cancel (libgcc_s.so.1 from the trusted dir)" "$progs/bin/cancel | grep -qx cancelled"
  check "libgcc_s loaded from libgccForGlibc" "LD_DEBUG=libs $progs/bin/cancel 2>&1 | grep -q \"$libgcc/lib64/libgcc_s.so.1\""
  check "locale via LOCPATH (langpack_de)" "[ \"\$(LOCPATH=$langpackDeOut/lib/locale LC_ALL=de_DE.UTF-8 $progs/bin/locale)\" = 'UTF-8 Sonntag' ]"
  check "P2: locale via LOCALE_ARCHIVE (all_langpacks' archive)" "[ \"\$(LOCALE_ARCHIVE=$allLangpacksOut/lib/locale/locale-archive LC_ALL=fr_FR.UTF-8 $progs/bin/locale)\" = 'UTF-8 dimanche' ]"
  check "P2: LOCALE_ARCHIVE_2_27 wins over LOCALE_ARCHIVE" "[ \"\$(LOCALE_ARCHIVE_2_27=$allLangpacksOut/lib/locale/locale-archive LOCALE_ARCHIVE=/nonexistent LC_ALL=fr_FR.UTF-8 $progs/bin/locale)\" = 'UTF-8 dimanche' ]"
  check "langpack_de setup hook adds LOCPATH" "grep -qx \"addToSearchPath LOCPATH \\\"$langpackDeOut/lib/locale\\\"\" $langpackDeOut/nix-support/setup-hook"
  check "-static hello runs" "$progs/bin/hello-static | grep -qx 'hello from rockyBoot.s1.glibc' && ! readelf -l $progs/bin/hello-static | grep -q INTERP"
  check "-m32 hello runs (32-bit loader in out/lib)" "$progs/bin/hello-m32 | grep -qx 'hello from rockyBoot.s1.glibc' && readelf -l $progs/bin/hello-m32 | grep -q \"interpreter: $G/lib/ld-linux.so.2\""
  check "C++ hello runs" "$progs/bin/hello-cxx | grep -qx 'hello c++'"

  # 5. the loader
  $G/lib64/ld-linux-x86-64.so.2 --list-diagnostics > $TMPDIR/diag.txt
  grep -E '^path\.' $TMPDIR/diag.txt | tee -a $TMPDIR/result.txt
  check "ld.so path.prefix = out" "grep -qx \"path.prefix=\\\"$G\\\"\" $TMPDIR/diag.txt"
  check "ld.so path.rtld = out loader" "grep -qx \"path.rtld=\\\"$G/lib64/ld-linux-x86-64.so.2\\\"\" $TMPDIR/diag.txt"
  check "ld.so system dirs = out/lib64, libgccForGlibc/lib64, libgccForGlibc/lib" \
    "[ \"\$(sed -n 's/^path.system_dirs\[0x[0-9a-f]*\]=\"\(.*\)\"$/\1/p' $TMPDIR/diag.txt | tr '\n' ' ')\" = \"$G/lib64/ $libgcc/lib64/ $libgcc/lib/ \" ]"
  # P1 prints PREFIX/etc as the loader's sysconfdir (ld.so.cache, ld.so.conf);
  # the rest of glibc keeps sysconfdir /etc (TZDEFAULT, nsswitch.conf, ...)
  check "ld.so path.sysconfdir = out/etc (P1)" "grep -qx \"path.sysconfdir=\\\"$G/etc\\\"\" $TMPDIR/diag.txt"
  check "libc keeps /etc: /etc/localtime, /etc/nsswitch.conf; no out/etc/localtime" "grep -q /etc/localtime $G/lib64/libc.so.6 && grep -q /etc/nsswitch.conf $G/lib64/libc.so.6 && ! grep -q $G/etc/localtime $G/lib64/libc.so.6"
  check "P1: ldconfig -p reads out/etc/ld.so.cache" "{ $G/sbin/ldconfig -p 2>&1 || true; } | grep -q \"$G/etc/ld.so.cache\""
  check "P2: LOCALE_ARCHIVE in libc.so.6" "grep -q LOCALE_ARCHIVE_2_27 $G/lib64/libc.so.6"
  check "P3: /etc/ld-nix.so.preload in ld.so, no /etc/ld.so.preload" "grep -q /etc/ld-nix.so.preload $G/lib64/ld-linux-x86-64.so.2 && ! grep -q /etc/ld.so.preload $G/lib64/ld-linux-x86-64.so.2"
  check "ld.so has no RPATH/RUNPATH" "! readelf -d $G/lib64/ld-linux-x86-64.so.2 | grep -qE '\((RPATH|RUNPATH)\)'"

  # 6. tools from other outputs
  check "getconf GNU_LIBC_VERSION" "[ \"\$($commonOut/bin/getconf GNU_LIBC_VERSION)\" = 'glibc 2.39' ]"
  check "iconv UTF-8 -> ISO-8859-1 (default gconv dir out/lib64/gconv)" "[ \"\$(printf '\\303\\244' | $commonOut/bin/iconv -f UTF-8 -t ISO-8859-1 | od -An -tx1 | tr -d ' ')\" = e4 ]"
  check "memusagestat: NEEDED libgd, no RUNPATH to build-only deps (S1)" "readelf -d $utilsOut/bin/memusagestat | grep -q 'libgd.so.3' && [ -z \"\$(rp $utilsOut/bin/memusagestat | grep -v \"^$G\" || true)\" ]"

  mkdir -p ''${outputs[out]}
  cp $TMPDIR/result.txt $TMPDIR/scan.txt $TMPDIR/diag.txt ''${outputs[out]}/
  [ $fail = 0 ]
'';
}
