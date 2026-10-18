# Rocky kernel-headers from the kernel SRPM: a real `rpmbuild --rebuild` of
# kernel-<EVR>.src.rpm in stage0, with every kernel/tools variant switched off
# so that only %prep (config generation), InitBuildVars and
# `make headers_install` run.  See docs/kernel-headers.md.
#
# Result: kernel-headers-<EVR>.x86_64.rpm (+ the always-emitted, empty
# kernel-modules-extra-matched meta package).
{ pkgs
, lib'          # lib/default.nix instance (buildSrpm, mkBuildroot, rpmTree, ...)
, buildroot     # stage0-full (bootstrap buildrootFull)
, rpm           # stage0 rpm (bootstrap/rpm.nix), used outside the chroot by the check
, macroRpms ? [ ]      # mkBuildroot rpm specs: python3-rpm-macros (%py3_shebang_fix in %prep),
                       # kernel-rpm-macros (BuildRequires); not part of stage0-full
, officialRpm ? null   # official kernel-headers RPM (lib/fetch-rpm.nix), for `check`
, configchecks ? true  # process_configs.sh -w -n -c, like the real build; docs/kernel-headers.md
}:
let
  inherit (pkgs) lib;

  # Tools kernel.spec's headers-only path executes that the stage0 base layer
  # lacks (bash-as-sh, gawk, python3, perl, git, flex, bison, make, gcc, tar,
  # xz are already there; the sb certs come from rocky-sb-certs, installed with
  # rocky-release in buildrootRelease).  A NEW layer, so the base root (and the
  # toolchain below it) stay untouched.
  #   openssl: %prep converts the Secure Boot certs (openssl x509 -inform der)
  #   rsync:   `make headers_install`
  #   bc:      in the effective BuildRequires; only kernel builds run it, cheap
  extraTools = [ pkgs.openssl pkgs.rsync pkgs.bc ];

  buildrootKernel = lib'.mkBuildroot {
    name = "stage0-kernel";
    base = buildroot;
    rpms = macroRpms;
    extraCommands = ''
      for p in ${lib.concatMapStringsSep " " (t: "${lib.getBin t}") extraTools}; do
        for f in $p/bin/*; do
          n=$(basename $f)
          [ -e "$BUILDROOT/usr/bin/$n" ] || [ -L "$BUILDROOT/usr/bin/$n" ] || ln -s $f "$BUILDROOT/usr/bin/$n"
        done
      done
      test -L "$BUILDROOT/usr/bin/openssl" && test -L "$BUILDROOT/usr/bin/rsync"
      # %prep reads these (rocky-sb-certs, from buildrootRelease)
      for c in kernel-dup1 kernel-kpatch1 kernel-nvidiagpuoot101; do
        test -e "$BUILDROOT/usr/share/pki/sb-certs/$c-x86_64.der"
      done
      test -e "$BUILDROOT/usr/share/pki/sb-certs/rocky-ima-ca.crt"
    '';
  };

  # kernel.spec switches (all `%define with_X %{?_without_X: 0} ...`).
  # Everything that would build a kernel, tools, perf, selftests, docs, UKIs or
  # extra packages is off; `headers` stays on.  docs/research/kernel-headers.md §1.1.
  withouts = [
    "debug" "up" "realtime" "perf" "libperf" "tools" "ynl" "selftests"
    "debuginfo" "kmap" "cross_headers" "doc" "efiuki" "kabichk" "kabidwchk"
    "vdso_install"
  ] ++ lib.optional (!configchecks) "configchecks";

  build = lib'.buildSrpm {
    srpm = "kernel";
    name = "kernel-headers";
    buildroot = buildrootKernel;
    rpmbuildArgs = lib.concatMap (w: [ "--without" w ]) withouts;
  };

  tree = lib'.rpmTree { inherit build; name = "kernel-headers"; };

  e = build.lockEntry;
  nevr = "kernel-headers-${e.version}-${e.release}";

  # The official RPM is produced by the full kernel build, in which libperf's
  # `install_headers` and cpupower's `install` write into the same buildroot
  # and `%files headers` is `/usr/include/*`: these 21 paths leak into it
  # (they are owned by libperf-devel / kernel-tools-libs-devel too).  A
  # headers-only build cannot produce them; we do not fake them.
  leakedPaths = [
    "/usr/include/cpuidle.h"
    "/usr/include/internal"
    "/usr/include/internal/cpumap.h"
    "/usr/include/internal/evlist.h"
    "/usr/include/internal/evsel.h"
    "/usr/include/internal/lib.h"
    "/usr/include/internal/mmap.h"
    "/usr/include/internal/rc_check.h"
    "/usr/include/internal/threadmap.h"
    "/usr/include/internal/xyarray.h"
    "/usr/include/perf"
    "/usr/include/perf/bpf_perf.h"
    "/usr/include/perf/core.h"
    "/usr/include/perf/cpumap.h"
    "/usr/include/perf/event.h"
    "/usr/include/perf/evlist.h"
    "/usr/include/perf/evsel.h"
    "/usr/include/perf/mmap.h"
    "/usr/include/perf/perf_dlfilter.h"
    "/usr/include/perf/threadmap.h"
    "/usr/include/powercap.h"
  ];

  # Comparison against the official RPM.  Output: report.txt (+ the raw
  # query outputs).  Fails on any unexpected difference.
  check = pkgs.runCommand "check-kernel-headers-vs-official" {
    nativeBuildInputs = [ pkgs.cpio pkgs.diffutils pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gawk pkgs.gnused ];
    passAsFile = [ "leaked" ];
    leaked = lib.concatStringsSep "\n" leakedPaths + "\n";
  } ''
    set -euo pipefail
    export RPM_CONFIGDIR=${rpm}/usr/lib/rpm
    q() { ${rpm}/usr/bin/rpm -qp --nosignature "$@"; }
    mkdir -p $out; cd $out
    exec > >(tee report.txt) 2>&1
    fail=0
    ok()  { echo "PASS: $1"; }
    bad() { echo "FAIL: $1"; fail=1; }
    chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

    ours=
    for f in ${build}/RPMS/*/*.rpm; do
      [ "$(q --qf '%{NAME}' "$f")" = kernel-headers ] && ours=$f
    done
    off=${if officialRpm != null then "${officialRpm}" else "\"\""}
    [ -n "$ours" ] || { echo "no kernel-headers rpm in ${build}"; exit 1; }
    [ -n "$off" ] || { echo "no official RPM given"; exit 1; }
    echo "ours:     $(basename $ours)"
    echo "official: $(basename $off)"
    echo "rpms built: $(cd ${build}/RPMS && echo */*.rpm)"
    echo

    # --- identity ---------------------------------------------------------
    chk "NEVR ours = ${nevr}" '[ "$(q --qf "%{NAME}-%{VERSION}-%{RELEASE}" $ours)" = ${nevr} ]'
    chk "NEVR official = ${nevr}" '[ "$(q --qf "%{NAME}-%{VERSION}-%{RELEASE}" $off)" = ${nevr} ]'
    chk "epoch/arch equal" '[ "$(q --qf "%{EPOCH}:%{ARCH}" $ours)" = "$(q --qf "%{EPOCH}:%{ARCH}" $off)" ]'
    chk "sourcerpm equal" '[ "$(q --qf "%{SOURCERPM}" $ours)" = "$(q --qf "%{SOURCERPM}" $off)" ]'
    chk "exactly 2 binary rpms (kernel-headers, kernel-modules-extra-matched)" \
      '[ "$(for f in ${build}/RPMS/*/*.rpm; do q --qf "%{NAME}\n" $f; done | sort | tr "\n" " ")" = "kernel-headers kernel-modules-extra-matched " ]'

    # --- metadata tags (must match) ----------------------------------------
    for t in SUMMARY DESCRIPTION LICENSE GROUP URL OS PLATFORM RPMVERSION; do
      a=$(q --qf "%{$t}" $ours); b=$(q --qf "%{$t}" $off)
      chk "tag $t equal" '[ "$a" = "$b" ]'
    done
    # informational: tags that identify the build system, not the content
    echo "-- informational tags (ours | official)"
    for t in BUILDHOST BUILDTIME VENDOR PACKAGER PAYLOADCOMPRESSOR PAYLOADFLAGS SIZE; do
      echo "   $t: $(q --qf "%{$t}" $ours) | $(q --qf "%{$t}" $off)"
    done

    # --- dependencies -------------------------------------------------------
    for d in provides requires obsoletes conflicts recommends suggests supplements enhances; do
      q --$d $ours | sort > ours.$d; q --$d $off | sort > off.$d
    done
    chk "provides include kernel-headers(x86-64) = ${e.version}-${e.release}" \
      'grep -qxF "kernel-headers(x86-64) = ${e.version}-${e.release}" ours.provides'
    for d in provides obsoletes conflicts recommends suggests supplements enhances; do
      chk "$d identical" 'diff -u off.$d ours.$d'
    done
    # rpmlib() requires follow the payload format the spec picked; anything
    # else must be identical
    grep -v '^rpmlib(' ours.requires > ours.requires.norpmlib || true
    grep -v '^rpmlib(' off.requires > off.requires.norpmlib || true
    chk "requires identical (ignoring rpmlib())" 'diff -u off.requires.norpmlib ours.requires.norpmlib'
    if ! diff -q off.requires ours.requires >/dev/null; then
      echo "   note: rpmlib() requires differ:"; diff off.requires ours.requires | sed 's/^/     /' || true
    fi
    chk "no /nix/store in any header tag" '! q --xml $ours | grep -q /nix/store'

    # --- file lists ---------------------------------------------------------
    q -l $ours | LC_ALL=C sort > ours.files
    q -l $off  | LC_ALL=C sort > off.files
    LC_ALL=C sort $leakedPath > leaked.expected
    LC_ALL=C comm -13 ours.files off.files > only-official
    LC_ALL=C comm -23 ours.files off.files > only-ours
    LC_ALL=C comm -12 ours.files off.files > common
    echo "paths: ours $(wc -l < ours.files), official $(wc -l < off.files), common $(wc -l < common)"
    chk "no paths only in ours" '[ ! -s only-ours ]'
    chk "paths only in official == the 21 leaked tools headers" 'diff -u leaked.expected only-official'

    # --- per-file metadata (mode, owner, group, mtime, digest, flags, links) -
    meta='[%{FILENAMES}\t%{FILEMODES:octal}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}\t%{FILEMTIMES}\t%{FILEDIGESTS}\t%{FILEFLAGS:fflags}\t%{FILELINKTOS}\n]'
    q --qf "$meta" $ours | LC_ALL=C sort > ours.meta
    q --qf "$meta" $off  | LC_ALL=C sort \
      | awk -F'\t' 'NR==FNR{keep[$1]=1; next} ($1 in keep)' common - > off.meta.common
    chk "mode/owner/group/mtime/digest/flags identical for every common path" 'diff -u off.meta.common ours.meta'

    # --- payload bytes --------------------------------------------------------
    mkdir -p x-ours x-off
    ${rpm}/usr/bin/rpm2cpio $ours | (cd x-ours && cpio -idm --quiet --no-absolute-filenames)
    ${rpm}/usr/bin/rpm2cpio $off  | (cd x-off  && cpio -idm --quiet --no-absolute-filenames)
    while read -r p; do rm -rf "x-off$p"; done < leaked.expected
    chk "extracted payloads byte-identical (official minus the 21 leaked paths)" 'diff -r x-off x-ours'
    sum=$(cd x-ours && find usr -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d" " -f1)
    chk "content oracle (docs/research/kernel-headers.md §3): $sum" \
      '[ "$sum" = 3c2cc5570191a364648006ffca5e60e0c5cfea8fe89234aee003ee744297d3f8 ]'
    chk "payload has no /nix/store strings" '! grep -rl /nix/store x-ours'
    echo "files: $(find x-ours -type f | wc -l), dirs: $(find x-ours/usr/include -type d | wc -l) (incl. /usr/include itself, not packaged)"
    rm -rf x-ours x-off

    echo
    if [ $fail = 0 ]; then echo "ALL KERNEL-HEADERS CHECKS PASSED"; else echo "SOME KERNEL-HEADERS CHECKS FAILED"; exit 1; fi
  '';
in
{
  inherit buildrootKernel build tree check leakedPaths withouts;
  # the binary RPM, for mkBuildroot's `rpms` list
  rpmSpec = { from = build; names = [ "kernel-headers" ]; };
}
