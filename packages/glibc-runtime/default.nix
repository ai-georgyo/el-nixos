# checks.glibc-runtime: our glibc RPMs WORK, in a root without /nix/store,
# and behave exactly like the official ones.
#
# Two roots made only of RPMs -- no nixpkgs, no busybox, /nix does not exist
# inside -- that differ only in the C library:
#   ours      our 12 glibc subpackages + our kernel-headers
#   official  the 13 official Rocky RPMs of the same names
# each on top of the same 34 official non-glibc Rocky RPMs (filesystem, setup,
# bash, coreutils-single, ... and their closure).  They are installed with
# rpm --root and scriptlets ON (chrooted: glibc's Lua %post runs our
# ldconfig/iconvconfig).  test.sh then prints a ~1500-line behaviour report
# (ld.so, ldd, ldconfig, locales, localedef, iconv/gconv, NSS incl. nss_db,
# getconf, tz, utilities, and programs compiled against each glibc-devel/
# -static: dynamic, dlopen, threads/TLS/cancel, NSS, libm, libcrypt, -static,
# -static-pie) in both roots, plus every locale of glibc-all-langpacks.
# The reports must be identical (minus the CPU's APIC id and inode numbers).
# All roots run in ONE derivation, i.e. on the same machine.
#
# Root helpers are kept from the verification that introduced this check
# (docs/glibc.md, "Runtime check").
{ pkgs
, stage0          # legacyPackages.stage0
, officialRpms    # name -> official RPM FOD
, build           # buildSrpm result of glibc (srpm.glibc)
, kernelHeadersBuild
}:
let
  inherit (pkgs) lib;
  L = stage0.lib;
  off = officialRpms;
  e = L.fetch.entry "glibc";

  baseLayer = pkgs.runCommand "glibc-runtime-root-base" { } "mkdir -p $out/usr/lib/sysimage/rpm $out/builddir";
  base = baseLayer // { layers = [ baseLayer ]; stage = 1; store = false; };

  # official Rocky RPMs, identical in both roots (the closure of bash,
  # coreutils-single, grep, sed, gzip, diffutils, tzdata, libgcc, libxcrypt
  # and the base packages)
  commonNames = [
    "audit-libs" "basesystem" "bash" "coreutils-single" "filesystem" "grep" "gzip" "diffutils"
    "libacl" "libattr" "libcap" "libcap-ng" "libeconf" "libgcc" "libpkgconf" "libselinux" "libsepol"
    "libxcrypt" "libxcrypt-devel" "libxcrypt-static" "ncurses-base" "ncurses-libs" "pam-libs" "pcre2"
    "pcre2-syntax" "pkgconf" "pkgconf-m4" "pkgconf-pkg-config" "rocky-gpg-keys" "rocky-release"
    "rocky-repos" "sed" "setup" "tzdata"
  ];
  # the glibc side (glibc-utils' perl/gd deps and glibc-locale-source's gzip
  # Requires are deliberately not satisfied -- same on both sides)
  glibcNames = [
    "glibc" "glibc-common" "glibc-minimal-langpack" "glibc-langpack-de" "glibc-langpack-en"
    "glibc-gconv-extra" "glibc-devel" "glibc-static" "glibc-utils" "libnsl" "nss_db" "glibc-locale-source"
  ];

  common = map (n: off.${n}) commonNames;
  oursSpecs = [ { from = build; names = glibcNames; } { from = kernelHeadersBuild; names = [ "kernel-headers" ]; } ];
  offSpecs = map (n: off.${n}) (glibcNames ++ [ "kernel-headers" ]);

  record = ''
    ${L.rpmOutside} --root "$BUILDROOT" -qa --qf '%{NEVRA}\n' | sort > "$BUILDROOT/rpm-qa.txt"
    ${L.rpmOutside} --root "$BUILDROOT" -Va > "$BUILDROOT/rpm-Va.txt" 2>&1 || true
  '';
  mkRoot = name: specs: L.mkBuildroot {
    name = "glibc-runtime-${name}";
    inherit base;
    rpms = common ++ specs;
    # scriptlets run; --nodeps: the closure is deliberately incomplete (above);
    # /var/spool/mail (root:mail) is excluded: the single-uid namespace cannot
    # chown to group mail (docs/glibc.md, "Known differences / open issues")
    installFlags = [ "--nodeps" "--excludepath=/var/spool/mail" ];
    extraCommands = record;
  };
  rootOurs = mkRoot "ours" oursSpecs;
  rootOff = mkRoot "official" offSpecs;
  rootOurs32 = L.mkBuildroot {
    name = "glibc-runtime-ours-glibc32";
    base = rootOurs;
    rpms = [ { from = build; names = [ "glibc32" ]; } ];
    installFlags = [ "--nodeps" ];
  };
  allLangpacks = name: root: spec: L.mkBuildroot {
    name = "glibc-runtime-${name}-all-langpacks";
    base = root;
    rpms = [ spec ];
    installFlags = [ "--nodeps" ];
  };
  rootOursAll = allLangpacks "ours" rootOurs { from = build; names = [ "glibc-all-langpacks" ]; };
  rootOffAll = allLangpacks "official" rootOff off.glibc-all-langpacks;

  # Programs compiled against each root's glibc-devel/-static: the stage0
  # binutils/gcc trees layered on top (the compiler executables need
  # /nix/store; crt files, libc.so, libc.a, headers are the root's RPMs').
  withCompiler = root: { layers = root.layers ++ [ stage0.binutils stage0.gcc ]; store = true; stage = 0; };
  compile = name: root: m32: L.runInBuildroot {
    name = "glibc-runtime-bins-${name}";
    buildroot = withCompiler root;
    root = true;
    binds = { "/src" = ./src; };
    script = ''
      gcc --version | head -1
      d=/builddir/out; cd /tmp
      gcc -O2 -Wl,-t /src/hello.c -o $d/hello > $d/hello.trace 2>&1
      gcc -O2 /src/dl.c -o $d/dl
      gcc -O2 -pthread /src/thr.c -o $d/thr
      gcc -O2 /src/nss.c -o $d/nss
      gcc -O2 /src/m.c -o $d/m -lm
      gcc -O2 /src/crypt.c -o $d/crypt -lcrypt
      gcc -O2 -static -pthread -Wl,-t /src/st.c -o $d/st -lm > $d/st.trace 2>&1
      gcc -O2 -static /src/nss.c -o $d/nss-static > $d/nss-static.log 2>&1 || echo "nss-static link failed" >> $d/nss-static.log
      gcc -O2 -fPIE -static-pie /src/m.c -o $d/m-spie -lm > $d/m-spie.log 2>&1 || echo "static-pie failed" >> $d/m-spie.log
      ${lib.optionalString m32 ''
        gcc -m32 -O2 -Wl,-t /src/hello.c -o $d/hello32 > $d/hello32.log 2>&1 || echo "m32 failed" >> $d/hello32.log
        gcc -m32 -O2 -static /src/m.c -o $d/m32-static -lm >> $d/hello32.log 2>&1 || echo "m32 static failed" >> $d/hello32.log
      ''}
      # the C library really comes from the root's RPMs (the linker trace
      # names crt1.o, libc.so.6, libc_nonshared.a under /usr), and nothing of
      # the store ends up in the programs
      grep -q 'lib64/crt1.o' $d/hello.trace
      grep -q 'libc.so.6' $d/hello.trace
      grep -q 'libc_nonshared.a' $d/hello.trace
      grep -q 'lib64/libc.a' $d/st.trace
      if grep -q /nix/store $d/hello.trace $d/st.trace; then echo "linked something from /nix/store" >&2; exit 1; fi
      if grep -a -l /nix/store $d/hello $d/st $d/thr; then echo "store path in a program" >&2; exit 1; fi
      ls -l $d
    '';
  };
  binsOurs = compile "ours" rootOurs32 true;
  binsOff = compile "official" rootOff false;
  bins = pkgs.runCommand "glibc-runtime-bins" { } "mkdir $out; cp -r ${binsOurs} $out/ours; cp -r ${binsOff} $out/off";

  runnerTools = with pkgs; [ bubblewrap coreutils findutils gnugrep gnused gawk diffutils attr cpio bash ];
  # "<label> <script> <layers...>" for every session
  sessions = [
    { label = "ours"; script = ./test.sh; root = rootOurs; }
    { label = "official"; script = ./test.sh; root = rootOff; }
    { label = "ours32"; script = ./test32.sh; root = rootOurs32; }
    { label = "ours-all-langpacks"; script = ./all-langpacks.sh; root = rootOursAll; }
    { label = "official-all-langpacks"; script = ./all-langpacks.sh; root = rootOffAll; }
  ];

  check = pkgs.stdenvNoCC.mkDerivation {
    name = "glibc-runtime-${e.version}-${e.release}";
    nativeBuildInputs = runnerTools;
    passthru = { inherit rootOurs rootOff rootOurs32 rootOursAll rootOffAll binsOurs binsOff bins; };
    buildCommand = ''
      set -euo pipefail
      source ${L.chrootLib}
      session() {  # label script layers...
        local label=$1 script=$2; shift 2
        echo "=== $label"
        chroot_setup $TMPDIR/st-$label "$@"
        mkdir -p $TMPDIR/bd-$label/out
        cp $script $TMPDIR/bd-$label/script.sh
        chroot_exec --root --bind $TMPDIR/bd-$label /builddir --ro-bind ${bins} /t --chdir /builddir \
          -- /bin/bash -euo pipefail /builddir/script.sh
        mkdir -p $out/$label
        cp -r $TMPDIR/bd-$label/out/. $out/$label/
      }
      ${lib.concatMapStrings (s: ''
        session ${s.label} ${s.script} ${lib.escapeShellArgs s.root.layers}
      '') sessions}

      # behavioural parity: identical reports, except the APIC id of the CPU
      # the process ran on (cpuid leaf 1 EBX) and inode numbers
      f() { grep -vE '^x86\.cpu_features\.features\[0x0\]\.cpuid\[0x1\]=|^[0-9]+ d' "$1"; }
      fail=0
      diff <(f $out/ours/report.txt) <(f $out/official/report.txt) > $out/diff.txt || fail=1
      diff <(f $out/ours-all-langpacks/report.txt) <(f $out/official-all-langpacks/report.txt) >> $out/diff.txt || fail=1
      cmp $out/ours-all-langpacks/all-locales.txt $out/official-all-langpacks/all-locales.txt >> $out/diff.txt || fail=1
      if [ $fail = 1 ]; then
        echo "glibc-runtime: our glibc behaves differently from the official one:" >&2
        head -200 $out/diff.txt >&2
        exit 1
      fi
      # ... and it works (both do): sanity anchors in the report
      r=$out/ours/report.txt
      grep -q 'No such file or directory' <(grep -A2 '^\$ ls -d /nix' $r)     # no /nix in the root
      grep -q '^glibc 2.39 stable' $r                                       # programs built against our glibc-devel
      grep -q '^total=800000 tlssum=364 main_tls=42' $r                     # threads + TLS
      grep -q '^cancelled=1' $r                                             # pthread_cancel (libgcc_s unwinding)
      grep -q '^static thread=42' $r                                        # -static: threads, libm
      grep -q '^iconv rc=0 byte=a4' $r                                      # -static: iconv (gconv)
      grep -q 'cache-identical-to-regenerated' $r                           # gconv-modules.cache
      grep -q '^pw: root /root /bin/bash' $r                                # NSS
      [ "$(grep -c '^\[rc=0\]' $r)" -gt 100 ]
      grep -q '^glibc 2.39 stable' $out/ours32/report.txt                   # 32-bit (glibc32)
      [ "$(grep -c . $out/ours-all-langpacks/all-locales.txt)" -gt 2000 ]
      echo "glibc-runtime: PASS -- $(grep -c . $r) report lines and $(grep -c '^== ' $out/ours-all-langpacks/all-locales.txt) locales identical to the official RPMs" | tee $out/result.txt
    '';
  };
in
check
