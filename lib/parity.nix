# RPM parity + purity checks: compare RPMs we build with the official Rocky
# RPMs (docs/parity.md). Plain derivations, no IFD: the official RPM list is
# taken from rpms.json (rpmsLock.bySrpm) at evaluation time; which binary
# packages a build produced is only discovered by the tool at build time.
#
#   mkParityCheck {
#     name     = "glibc";
#     ours     = <buildSrpm result> | <.rpm / dir of rpms> | [ ... ];
#     srpm     ? ours.srpmName            # selects rpmsLock.bySrpm.<srpm>
#     official ? <fetchRpm of every key in rpmsLock.bySrpm.<srpm>, filtered>
#     allow    ? tools/parity/<srpm>.json if it exists, else none
#                (path or list of paths; tools/parity/default.json is always loaded)
#     exclude  ? [ ]   # regexes over NAME.ARCH (full match), applied to both sides
#     keep     ? [ ]   # regexes that override `exclude`
#     deep     ? false # also compare ELF/ar facts of identical files
#     failOnDiff ? true
#     extraArgs  ? [ ] # passed to tools/rpm-parity.py
#   }
#   -> derivation: $out/report.md, $out/report.json; the build FAILS on any
#      unexpected difference or /nix/store reference (unless failOnDiff = false).
#      passthru.report = the same check with failOnDiff = false (always builds).
{ pkgs, rpmsLock, fetchRpm, stage0 ? null }:
let
  inherit (pkgs) lib;

  # only the tool + its allowlists (editing other tools does not rebuild checks)
  tool = lib.fileset.toSource {
    root = ../tools;
    fileset = lib.fileset.unions [ ../tools/rpm-parity.py ../tools/rpm_purity.py ../tools/parity ];
  };
  allowDir = ../tools/parity;

  matchesAny = res: key: lib.any (re: builtins.match re key != null) res;
  selected = exclude: keep: key: matchesAny keep key || !(matchesAny exclude key);

  rpmArg = x:
    if lib.isDerivation x && (x.isSrpmBuild or false) then "${x}/RPMS" else "${x}";

  mkParityCheck =
    { name
    , ours
    , srpm ? null
    , official ? null
    , allow ? null
    , exclude ? [ ]
    , keep ? [ ]
    , deep ? false
    , failOnDiff ? true
    , extraArgs ? [ ]
    }@args:
    let
      oursList = lib.toList ours;
      srpm' =
        if srpm != null then srpm
        else (lib.findFirst (x: lib.isAttrs x && x ? srpmName) { srpmName = null; } oursList).srpmName;
      allKeys =
        if official != null then [ ]
        else if srpm' == null then throw "mkParityCheck ${name}: pass `srpm` or `official`"
        else rpmsLock.bySrpm.${srpm'} or (throw "mkParityCheck ${name}: no SRPM '${srpm'}' in rpms.json bySrpm");
      keys = builtins.filter (selected exclude keep) allKeys;
      skipped = lib.subtractLists keys allKeys;
      officialList = if official != null then lib.toList official else map fetchRpm keys;
      # tools/parity/<srpm>.json, referenced inside the tool's store copy
      # (so its "extends" resolve next to it)
      allowList =
        if allow != null then lib.toList allow
        else lib.optional (srpm' != null && builtins.pathExists (allowDir + "/${srpm'}.json"))
          "${tool}/parity/${srpm'}.json";
      toolArgs =
        [ "--name" name "--out" (placeholder "out") ]
        ++ [ "--ours" ] ++ map rpmArg oursList
        ++ [ "--official" ] ++ map rpmArg officialList
        ++ lib.concatMap (a: [ "--allow" "${a}" ]) allowList
        ++ lib.concatMap (r: [ "--exclude" r ]) exclude
        ++ lib.concatMap (r: [ "--keep" r ]) keep
        ++ lib.concatMap (k: [ "--excluded-official" k ]) skipped
        ++ lib.optional deep "--deep"
        ++ extraArgs;
    in
    pkgs.runCommand "parity-${name}"
      {
        nativeBuildInputs = [ pkgs.python3 pkgs.zstd ];
        passthru = {
          inherit officialList allowList;
          officialKeys = keys;
          report = mkParityCheck (args // { failOnDiff = false; });
        };
        meta.description = "RPM parity/purity check: ${name} vs official Rocky RPMs";
      }
      ''
        rc=0
        python3 -I ${tool}/rpm-parity.py ${lib.escapeShellArgs toolArgs} || rc=$?
        if [ $rc -ge 2 ]; then echo "rpm-parity: tool error" >&2; exit $rc; fi
        ${if failOnDiff then ''
          if [ $rc -ne 0 ]; then
            echo "=== parity check ${name} FAILED; full report: $out/report.md (build with .report to keep it)" >&2
            exit 1
          fi
        '' else ""}
      '';

  # ------------------------------------------------------------------ checks
  # Self-tests of the tool + the stage0 validations (docs/parity.md).
  glibcBaselineFilter = {
    exclude = [ "glibc-langpack-.*" ];
    keep = [ "glibc-langpack-en\\..*" ];
  };
  glibcOfficial = map fetchRpm (builtins.filter
    (selected glibcBaselineFilter.exclude glibcBaselineFilter.keep)
    rpmsLock.bySrpm.glibc);

  # a tiny rpm whose payload and header mention /nix/store (built with
  # nixpkgs' rpmbuild, outside any chroot): the purity scan must catch it
  impureRpm = pkgs.runCommand "parity-impure-rpm" { nativeBuildInputs = [ pkgs.rpm ]; } ''
    cd $TMPDIR
    mkdir -p top tmp
    cat > impure.spec <<'EOF'
    Name: parity-impure
    Version: 1
    Release: 1
    Summary: purity negative test
    License: MIT
    BuildArch: noarch
    %description
    test
    %install
    mkdir -p %{buildroot}/usr/share/parity-impure
    echo "interpreter=/nix/store/00000000000000000000000000000000-bash/bin/sh" > %{buildroot}/usr/share/parity-impure/conf
    ln -s /nix/store/00000000000000000000000000000000-foo %{buildroot}/usr/share/parity-impure/link
    %files
    /usr/share/parity-impure
    EOF
    HOME=$TMPDIR rpmbuild -bb --quiet --define "_topdir $TMPDIR/top" --define "_tmppath $TMPDIR/tmp" \
      --define '__os_install_post %{nil}' \
      --define '_build_id_links none' --define '_binary_payload w9.gzdio' --nodeps impure.spec
    mkdir -p $out
    cp top/RPMS/noarch/*.rpm $out/
  '';

  # the same, but every store path is HIDDEN: in a gzip'ed man page and in
  # the xz-compressed .gnu_debugdata of an ELF library (the raw bytes of
  # every payload file are clean) -- the nested purity scan must find both
  nestedImpureRpm = pkgs.runCommandCC "parity-nested-impure-rpm"
    { nativeBuildInputs = [ pkgs.rpm pkgs.xz ]; NIX_NO_SELF_RPATH = "1"; } ''
    cd $TMPDIR
    mkdir -p top tmp src
    printf '.TH X 1\n.SH FILES\n/nix/store/00000000000000000000000000000000-perl/bin/perl\n' | gzip -9n > src/x.1.gz
    printf 'int f(void){return 0;}\n' > f.c
    gcc -O2 -fPIC -shared -nostdlib -Wl,-soname,libf.so.1 f.c -o libf.so.1
    printf 'hidden /nix/store/11111111111111111111111111111111-hidden\0' | xz -c > dd.xz
    objcopy --add-section .gnu_debugdata=dd.xz libf.so.1 src/libf.so.1
    if grep -q /nix/store src/libf.so.1 src/x.1.gz; then echo "fixture leaks raw store paths" >&2; exit 1; fi
    cat > nested.spec <<EOF
    Name: parity-nested-impure
    Version: 1
    Release: 1
    Summary: nested purity negative test
    License: MIT
    %description
    test
    %install
    install -Dm644 $TMPDIR/src/x.1.gz %{buildroot}/usr/share/man/man1/x.1.gz
    install -Dm755 $TMPDIR/src/libf.so.1 %{buildroot}/usr/lib/libf.so.1
    %files
    /usr/share/man/man1/x.1.gz
    /usr/lib/libf.so.1
    EOF
    HOME=$TMPDIR rpmbuild -bb --quiet --define "_topdir $TMPDIR/top" --define "_tmppath $TMPDIR/tmp" \
      --define '__os_install_post %{nil}' --define 'debug_package %{nil}' \
      --define '_build_id_links none' --define '_binary_payload w9.gzdio' --nodeps nested.spec
    mkdir -p $out
    cp top/RPMS/*/*.rpm $out/
  '';

  # two builds of "abitest" whose libx.so.1 differ ONLY in the dynamic
  # symbol table: official exports foo@@X_1.0 and bar@@X_1.0, ours drops bar.
  # rpm's auto-Provides are identical (libx.so.1(X_1.0)(64bit)), so only the
  # elf.dynsym comparison can tell them apart.
  abiRpms = pkgs.runCommandCC "parity-abi-rpms"
    { nativeBuildInputs = [ pkgs.rpm ]; NIX_NO_SELF_RPATH = "1"; } ''
    cd $TMPDIR
    printf 'int foo(void){return 1;}\nint bar(void){return 2;}\n' > official.c
    printf 'int foo(void){return 1;}\n' > ours.c
    printf 'X_1.0 { global: foo; bar; local: *; };\n' > official.map
    printf 'X_1.0 { global: foo; local: *; };\n' > ours.map
    for v in official ours; do
      mkdir -p $v/top $v/tmp $v/src
      gcc -O2 -fPIC -shared -nostdlib -Wl,-soname,libx.so.1 -Wl,--version-script=$v.map \
        -o $v/src/libx.so.1 $v.c
      if grep -q /nix/store $v/src/libx.so.1; then echo "fixture leaks store paths" >&2; exit 1; fi
      cat > $v/x.spec <<EOF
    Name: abitest
    Version: 1
    Release: 1
    Summary: ABI negative test
    License: MIT
    %description
    test
    %install
    install -Dm755 $TMPDIR/$v/src/libx.so.1 %{buildroot}/usr/lib64/libx.so.1
    %files
    /usr/lib64/libx.so.1
    EOF
      HOME=$TMPDIR rpmbuild -bb --quiet --define "_topdir $TMPDIR/$v/top" --define "_tmppath $TMPDIR/$v/tmp" \
        --define '__os_install_post %{nil}' --define 'debug_package %{nil}' \
        --define '_build_id_links none' --define '_binary_payload w9.gzdio' --nodeps $v/x.spec
      mkdir -p $out/$v
      cp $v/top/RPMS/*/*.rpm $out/$v/
    done
    # the premise: identical automatic Provides
    q() { rpm -qp --nosignature --provides "$1" | sort; }
    [ "$(q $out/ours/*.rpm)" = "$(q $out/official/*.rpm)" ]
  '';

  # run the tool, expect FAIL, and require the given strings in report.json
  expectFail = { name, args, mustContain }:
    pkgs.runCommand "parity-selftest-${name}"
      { nativeBuildInputs = [ pkgs.python3 pkgs.zstd ]; }
      ''
        rc=0
        python3 -I ${tool}/rpm-parity.py --name ${name} --out $out ${lib.escapeShellArgs args} || rc=$?
        [ $rc -eq 1 ] || { echo "expected exit 1 (FAIL), got $rc" >&2; exit 1; }
        for s in ${lib.escapeShellArgs mustContain}; do
          grep -qF -- "$s" $out/report.json || { echo "report.json lacks: $s" >&2; exit 1; }
        done
        echo "negative test ${name}: FAIL as expected" > $out/result.txt
      '';

  # rpm_purity.py (the build-time scanner) on its own: exit 1 + the hits
  purityScanFails = { name, rpms, mustContain }:
    pkgs.runCommand "purity-selftest-${name}"
      { nativeBuildInputs = [ pkgs.python3 pkgs.zstd ]; }
      ''
        rc=0
        python3 -I ${tool}/rpm_purity.py --json $TMPDIR/r.json ${rpms} || rc=$?
        [ $rc -eq 1 ] || { echo "expected exit 1 (store path found), got $rc" >&2; exit 1; }
        for s in ${lib.escapeShellArgs mustContain}; do
          grep -qF -- "$s" $TMPDIR/r.json || { echo "purity report lacks: $s" >&2; exit 1; }
        done
        mkdir $out; cp $TMPDIR/r.json $out/
      '';

  checks = {
    # official glibc (16 packages: all but the langpacks, langpack-en kept) vs
    # itself: zero differences expected; --deep parses every ELF/ar file and
    # payload digests are verified against the headers
    parity-glibc-official-self = mkParityCheck ({
      name = "glibc-official-self";
      srpm = "glibc";
      ours = glibcOfficial;    # official defaults to rpmsLock.bySrpm.glibc, same filter
      allow = [ ];
      deep = true;
      extraArgs = [ "--fail-on-unused" ];
    } // glibcBaselineFilter);

    parity-selftest-purity = expectFail {
      name = "purity";
      args = [ "--ours" "${impureRpm}" "--official" "${impureRpm}" ];
      mustContain = [ ''"purity_violations": 3'' "/usr/share/parity-impure/conf" "FILELINKTOS" ];
    };
    # store paths hidden in nested compression (gzip man page, xz
    # .gnu_debugdata): both the parity tool and the build-time scanner
    parity-selftest-purity-nested = expectFail {
      name = "purity-nested";
      args = [ "--ours" "${nestedImpureRpm}" "--official" "${nestedImpureRpm}" ];
      mustContain = [ ''"purity_violations": 2'' "payload>gzip" "payload>.gnu_debugdata" ];
    };
    purity-selftest-nested = purityScanFails {
      name = "nested";
      rpms = nestedImpureRpm;
      mustContain = [ "payload>gzip" "payload>.gnu_debugdata" "/usr/share/man/man1/x.1.gz" "/usr/lib/libf.so.1" ];
    };
    purity-selftest-plain = purityScanFails {
      name = "plain";
      rpms = impureRpm;
      mustContain = [ "/usr/share/parity-impure/conf" "symlink" ];
    };
    # a symbol removed from an existing version node (same rpm Provides)
    parity-selftest-abi = expectFail {
      name = "abi";
      args = [ "--ours" "${abiRpms}/ours" "--official" "${abiRpms}/official" ];
      mustContain = [ "elf.dynsym:/usr/lib64/libx.so.1:-bar@@X_1.0 FUNC GLOBAL DEFAULT .text"
                      "elf.alloc:/usr/lib64/libx.so.1:.dynsym" ];
    };
    # the binutils-based ABI cross-check (tools/abi-compare.py, checks.glibc-abi)
    # must catch the same removed symbol
    abi-compare-selftest = pkgs.runCommand "abi-compare-selftest"
      { nativeBuildInputs = [ pkgs.python3 pkgs.binutils-unwrapped pkgs.rpm pkgs.cpio ]; } ''
        for v in ours official; do
          mkdir -p $TMPDIR/$v && (cd $TMPDIR/$v && rpm2cpio ${abiRpms}/$v/*.rpm | cpio -idm --quiet --no-absolute-filenames)
        done
        rc=0
        python3 -I ${lib.fileset.toSource { root = ../tools; fileset = ../tools/abi-compare.py; }}/abi-compare.py \
          --pair abitest $TMPDIR/ours $TMPDIR/official --out $out || rc=$?
        [ $rc -eq 1 ] || { echo "expected exit 1 (FAIL), got $rc" >&2; exit 1; }
        grep -qF 'abi.dynsym:/usr/lib64/libx.so.1' $out/report.txt
        grep -qF -- '-bar@@X_1.0 FUNC GLOBAL DEFAULT DEF' $out/report.txt
      '';
    # comparing nothing is a tool error (exit 2), never a PASS
    parity-selftest-empty = pkgs.runCommand "parity-selftest-empty"
      { nativeBuildInputs = [ pkgs.python3 pkgs.zstd ]; } ''
        mkdir -p $TMPDIR/a $TMPDIR/b
        rc=0
        python3 -I ${tool}/rpm-parity.py --name empty --out $TMPDIR/o --ours $TMPDIR/a --official $TMPDIR/b || rc=$?
        [ $rc -eq 2 ] || { echo "expected exit 2 (nothing compared), got $rc" >&2; exit 1; }
        echo "empty comparison: tool error as expected" > $out
      '';
  } // lib.optionalAttrs (stage0 != null) {
    parity-which = mkParityCheck { name = "which"; ours = stage0.srpm.which; };
    parity-redhat-rpm-config = mkParityCheck {
      name = "redhat-rpm-config";
      ours = stage0.srpm.redhat-rpm-config;
      extraArgs = [ "--deep" ];
    };
    # without any allowlist, the which comparison must fail with the
    # differences we know exist (proves the comparisons actually fire)
    parity-selftest-noallow = expectFail {
      name = "noallow";
      args = [ "--no-default-allow" "--ours" "${stage0.srpm.which}/RPMS" "--official" "${fetchRpm "which.x86_64"}" ];
      mustContain = [
        "header.BUILDHOST" "header.OPTFLAGS" "redhat-annobin-cc1" "content.elf:/usr/bin/which"
        "package.only-ours:which-debuginfo.x86_64" "elf.alloc:/usr/bin/which:.text" "header.PAYLOADDIGESTALT"
      ];
    };
  };
in
{
  inherit mkParityCheck checks impureRpm nestedImpureRpm abiRpms;
  tool = "${tool}/rpm-parity.py";
}
