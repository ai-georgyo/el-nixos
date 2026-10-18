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
    fileset = lib.fileset.unions [ ../tools/rpm-parity.py ../tools/parity ];
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
        "package.only-ours:which-debuginfo.x86_64" "file.class:/usr/share/man/man1/which.1.gz"
      ];
    };
  };
in
{
  inherit mkParityCheck checks impureRpm;
  tool = "${tool}/rpm-parity.py";
}
