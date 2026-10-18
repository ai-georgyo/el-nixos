# checks.nn-glibc-runtime (design §7.6, WP9): the relocated glibc WORKS from
# the store, in a root with no /usr, no /lib64 and no /bin, and behaves like
# the official RPMs.
#
# One derivation runs two sessions of the same driver (driver.sh, POSIX sh
# under one static busybox) on the same machine (CPU-dependent output such
# as hwcaps and cache sizes must match):
#   official   the official-RPM roots of checks.glibc-runtime (34 base RPMs +
#              13 official glibc RPMs + glibc-all-langpacks; packages/
#              glibc-runtime), entered with the chroot runner; programs
#              compiled there against the official glibc-devel/-static
#   relocated  bwrap: tmpfs root, only the store closure of the glibc outputs,
#              the test programs and libgccForGlibc bound, /etc = a copy of
#              the official root's /etc (runtime FHS, design §1.4),
#              TZDIR = the official root's zoneinfo (profiles set TZDIR);
#              PATH = the outputs' bin/sbin, LOCPATH = every langpack +
#              common, GCONV_PATH = gconv_extra, I18NPATH = common +
#              locale_source (what the setup hooks export), archive mode:
#              LOCALE_ARCHIVE = all_langpacks (P2);
#              programs compiled by `cc` (the S1 wrapper over this glibc):
#              dynamic, -static, -static-pie, -m32 (glibc32 merged in out)
# tools/nn-parity.py runtime compares report.txt, locales.txt and
# locales-archive.txt item by item after normalisation (output paths ->
# /usr, libgccForGlibc -> <libgcc>, usrmerge spellings, addresses);
# allowlist tools/parity/nn-glibc-runtime.json.  relocated.txt (no official
# counterpart: -m32, archive vs LOCPATH, pthread_cancel through the trusted
# dir, P1) and p3.txt (P3) are checked by assertions below.
#
# Arguments: see lib/rocky/nn-checks/glibc.nix.
{ pkgs, lib, stage0, officialRpms, tool, allowFile ? null }:
{ name, glibc, outPaths, cc, libgcc, kernelHeaders, langpackNames, failOnDiff ? true }:
let
  L = stage0.lib;
  e = L.fetch.entry "glibc";

  # the official roots and their compiler layering, as checks.glibc-runtime
  # builds them (only the official side is used; `build` is never forced)
  fhsRuntime = import ../glibc-runtime {
    inherit pkgs stage0 officialRpms;
    build = throw "glibc-nn-runtime: the FHS build is not used";
    kernelHeadersBuild = stage0.kernelHeadersBuild;
  };
  rootOffAll = fhsRuntime.rootOffAll;
  rootOff = fhsRuntime.rootOff;
  # the same + every official langpack RPM: the locale directories that the
  # relocated LOCPATH mode reaches (no locale-archive in this root)
  rootOffLangpacks = L.mkBuildroot {
    name = "glibc-nn-runtime-official-langpacks";
    base = rootOff;
    # (de and en are in rootOff already)
    rpms = map (n: officialRpms.${n}) (lib.subtractLists [ "glibc-langpack-de" "glibc-langpack-en" ] langpackNames);
    installFlags = [ "--nodeps" ];
  };

  src = pkgs.runCommand "glibc-nn-runtime-src" { } ''
    mkdir -p $out
    cp ${../glibc-runtime/src}/{hello,dl,thr,nss,m,st}.c ${./src}/loc.c $out/
  '';
  busybox = "${pkgs.pkgsStatic.busybox}/bin/busybox";

  # programs against the official glibc (stage0 gcc in the official root)
  binsOff = L.runInBuildroot {
    name = "glibc-nn-runtime-bins-official";
    buildroot = { layers = rootOff.layers ++ [ stage0.binutils stage0.gcc ]; store = true; stage = 0; };
    root = true;
    binds = { "/src" = src; };
    script = ''
      d=/builddir/out; cd /tmp
      gcc -O2 /src/hello.c -o $d/hello
      gcc -O2 /src/dl.c -o $d/dl
      gcc -O2 -pthread /src/thr.c -o $d/thr
      gcc -O2 /src/nss.c -o $d/nss
      gcc -O2 /src/m.c -o $d/m -lm
      gcc -O2 /src/loc.c -o $d/loc
      gcc -O2 -static -pthread /src/st.c -o $d/st -lm
      gcc -O2 -static /src/nss.c -o $d/nss-static 2> $d/nss-static.log
      gcc -O2 -fPIE -static-pie /src/m.c -o $d/m-spie -lm
    '';
  };

  # programs against the relocated glibc, built by the S1 wrapper from PATH
  # (no stdenv setup hooks: exactly what the wrapper adds by itself)
  binsOurs = pkgs.runCommand "glibc-nn-runtime-bins-${name}" {
    nativeBuildInputs = [ pkgs.binutils-unwrapped pkgs.patchelf ];
  } ''
    set -euo pipefail
    mkdir -p $out; d=$out; cd $TMPDIR
    cc() { ${cc}/bin/gcc -idirafter ${kernelHeaders} "$@"; }
    cc -O2 ${src}/hello.c -o $d/hello
    cc -O2 ${src}/dl.c -o $d/dl
    cc -O2 -pthread ${src}/thr.c -o $d/thr
    cc -O2 ${src}/nss.c -o $d/nss
    cc -O2 ${src}/m.c -o $d/m -lm
    cc -O2 ${src}/loc.c -o $d/loc
    cc -O2 -static -L${outPaths.static}/lib64 -pthread ${src}/st.c -o $d/st -lm
    cc -O2 -static -L${outPaths.static}/lib64 ${src}/nss.c -o $d/nss-static 2> $d/nss-static.log
    cc -O2 -fPIE -static-pie -L${outPaths.static}/lib64 ${src}/m.c -o $d/m-spie -lm
    # glibc32 (merged into out) has gnu/stubs-32.h; the wrapper only adds dev/include
    cc -m32 -O2 -idirafter ${out}/include ${src}/hello.c -o $d/hello32
    cc -m32 -O2 -idirafter ${out}/include -static ${src}/m.c -o $d/m32-static -lm
    for f in hello dl thr nss m loc hello32; do
      echo "== $f"; readelf -lW $d/$f | grep -E 'interpreter' || true
      readelf -dW $d/$f | grep -E 'NEEDED|RUNPATH|RPATH' || true
    done > $d/elf-facts.txt
    cat $d/elf-facts.txt
    # The wrapper's ld adds every -L dir holding a lib<x>.so as RUNPATH
    # ($dev/lib64, gcc's lib dir: handoff, cc notes; rocky-partition's
    # Phase E drops them in package builds).  The programs need none: libc,
    # libm come from the loader's system dir, libgcc_s from the trusted dir.
    for f in hello dl thr nss m loc hello32; do patchelf --remove-rpath $d/$f; done
  '';

  inherit (outPaths) out;
  binDirs = lib.concatMap (o: [ "${outPaths.${o}}/bin" "${outPaths.${o}}/sbin" ])
    ([ "common" "out" ] ++ lib.filter (o: o != "common" && o != "out") (lib.attrNames outPaths));
  locDirs = map (o: "${outPaths.${o}}/lib/locale")
    (lib.filter (o: lib.hasPrefix "langpack_" o || o == "minimal_langpack" || o == "common") (lib.attrNames outPaths));

  # charmaps (common) and locale sources (locale_source): the I18NPATH that
  # the setup hooks export
  i18nDirs = map (o: "${outPaths.${o}}/share/i18n") (lib.attrNames outPaths);

  closureRoots = pkgs.writeText "nn-${name}-runtime-roots"
    (lib.concatStringsSep "\n" (lib.attrValues outPaths ++ [ "${binsOurs}" "${libgcc}" ]));

  plan = pkgs.writeText "nn-${name}-runtime-plan.json" (builtins.toJSON {
    name = "${name}-runtime";
    outputs = outPaths;
    rpmOutputs = { };
    # (an attribute name cannot carry string context; libgcc is an input
    # through closureRoots)
    map = { ${builtins.unsafeDiscardStringContext "${libgcc}"} = "<libgcc>"; };
  });

  check = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-${name}-runtime";
    nativeBuildInputs = with pkgs; [ bubblewrap coreutils findutils gnugrep gnused gawk diffutils python3 bash ];
    # everything the relocated root may contain: the closure of these roots
    exportReferencesGraph = [ "closure" closureRoots ];
    passthru = { inherit binsOurs binsOff rootOff rootOffAll rootOffLangpacks plan; };
    buildCommand = ''
      set -euo pipefail
      source ${L.chrootLib}
      mkdir -p $out
      prep_t() {  # dir bins
        mkdir -p $1; cp -r $2/. $1/; chmod -R u+w $1
        cp ${busybox} $1/busybox; cp ${./driver.sh} $1/driver.sh
      }

      # ---------------------------------------------------------- official
      prep_t $TMPDIR/t-off ${binsOff}
      mkdir -p $TMPDIR/w-off/out
      official() {  # phase
        chroot_exec --root --bind $TMPDIR/w-off /work --ro-bind $TMPDIR/t-off /t --chdir /work \
          --setenv MODE official --setenv PHASE $1 --setenv LDSO /usr/lib64/ld-linux-x86-64.so.2 \
          --setenv LIBC /usr/lib64/libc.so.6 --setenv T /t --setenv BB /t/busybox --setenv OUT /work/out \
          --setenv PATH /usr/bin:/usr/sbin -- /t/busybox sh /t/driver.sh
      }
      echo "=== official session: main (official RPMs + glibc-all-langpacks)"
      chroot_setup $TMPDIR/st-off ${lib.escapeShellArgs rootOffAll.layers}
      official main
      # the official root's /etc and zoneinfo, for the relocated root
      chroot_exec --root --bind $TMPDIR/w-off /work -- /bin/sh -c \
        'cp -a --no-preserve=ownership /etc /work/etc && cp -a --no-preserve=ownership /usr/share/zoneinfo /work/zoneinfo'
      echo "=== official session: locales (official RPMs + every langpack)"
      chroot_setup $TMPDIR/st-off-lp ${lib.escapeShellArgs rootOffLangpacks.layers}
      official locales
      mkdir -p $out/official; cp $TMPDIR/w-off/out/* $out/official/

      # ---------------------------------------------------------- relocated
      echo "=== relocated session"
      prep_t $TMPDIR/t ${binsOurs}
      mkdir -p $TMPDIR/w/out
      etc=$TMPDIR/etc; cp -a $TMPDIR/w-off/etc $etc; chmod -R u+w $etc
      zi=$TMPDIR/zoneinfo; cp -a $TMPDIR/w-off/zoneinfo $zi
      binds=()
      while read -r p; do binds+=(--ro-bind "$p" "$p"); done < <(grep '^/nix/store/' closure | sort -u)
      locpath=""
      for d in ${lib.escapeShellArgs locDirs}; do [ -d "$d" ] && locpath="$locpath''${locpath:+:}$d"; done
      i18n=""
      for d in ${lib.escapeShellArgs i18nDirs}; do [ -d "$d" ] && i18n="$i18n''${i18n:+:}$d"; done
      path=""
      for d in ${lib.escapeShellArgs binDirs}; do [ -d "$d" ] && path="$path''${path:+:}$d"; done
      archive=${outPaths.all_langpacks or "/nonexistent"}/lib/locale/locale-archive
      [ -e "$archive" ] || archive=$archive.real
      relocated() {   # extra bwrap args -- cmd...
        local extra=()
        while [ "$1" != -- ]; do extra+=("$1"); shift; done; shift
        env --default-signal=PIPE bwrap --unshare-user --uid 0 --gid 0 --cap-add ALL --unshare-ipc --unshare-pid \
          --tmpfs / "''${binds[@]}" --proc /proc --dev /dev --tmpfs /tmp \
          --bind $etc /etc --ro-bind $zi /zoneinfo --bind $TMPDIR/w /work --ro-bind $TMPDIR/t /t --chdir /work \
          --clearenv --setenv MODE relocated --setenv LDSO ${out}/lib64/ld-linux-x86-64.so.2 \
          --setenv PHASE "''${PHASE:-main}" \
          --setenv LDSO32 ${out}/lib/ld-linux.so.2 --setenv LIBC ${out}/lib64/libc.so.6 \
          --setenv T /t --setenv BB /t/busybox --setenv OUT /work/out --setenv PATH "$path" \
          --setenv LOCPATH_ALL "$locpath" --setenv ARCHIVE "$archive" --setenv I18NPATH_ALL "$i18n" \
          --setenv GCONV_EXTRA ${outPaths.gconv_extra or "/nonexistent"}/lib64/gconv --setenv TZDIR /zoneinfo \
          "''${extra[@]}" -- "$@"
      }
      PHASE=main relocated -- /t/busybox sh /t/driver.sh
      PHASE=locales relocated -- /t/busybox sh /t/driver.sh
      # P3: /etc/ld.so.preload must be ignored, /etc/ld-nix.so.preload used
      {
        echo /nonexistent/libnn-preload.so > $etc/ld.so.preload
        echo "### p3.ld.so.preload"; relocated -- /t/hello 2>&1 | head -3 || true
        rm $etc/ld.so.preload
        echo /nonexistent/libnn-preload.so > $etc/ld-nix.so.preload
        echo "### p3.ld-nix.so.preload"; relocated -- /t/hello 2>&1 | head -3 || true
        rm $etc/ld-nix.so.preload
      } > $TMPDIR/w/out/p3.txt
      mkdir -p $out/relocated; cp $TMPDIR/w/out/* $out/relocated/
      cp ${binsOurs}/elf-facts.txt $out/

      # ---------------------------------------------------------- compare
      rc=0
      python3 -I ${tool}/nn-parity.py runtime --plan ${plan} --ours $out/relocated --official $out/official \
        ${lib.optionalString (allowFile != null) "--allow ${allowFile}"} --out $out/compare || rc=$?
      [ $rc -lt 2 ] || { echo "nn-parity runtime: tool error" >&2; exit $rc; }

      # ---------------------------------------------------------- assertions
      fails=()
      a() { if ! grep -qE -- "$2" "$3"; then fails+=("$1"); echo "ASSERT FAILED: $1 ($2 in ''${3##*/})"; else echo "ok: $1"; fi; }
      n() { if grep -qE -- "$2" "$3"; then fails+=("$1"); echo "ASSERT FAILED: $1 (no $2 in ''${3##*/})"; else echo "ok: $1"; fi; }
      R=$out/relocated
      {
        a "relocated root checked for /usr, /lib64, /bin" '^### r.env.no-usr' $R/relocated.txt
        n "no /usr, /lib64, /bin in the relocated root" ' exists$' $R/relocated.txt
        a "dynamic program runs" '^glibc 2\.39 stable' $R/report.txt
        a "static program runs (threads, libm)" '^static thread=42' $R/report.txt
        a "static program: iconv (gconv)" '^iconv rc=0 byte=a4' $R/report.txt
        a "NSS files" '^pw: root /root /bin/bash' $R/report.txt
        a "-m32 dynamic program" '^glibc 2\.39 stable' $R/relocated.txt
        a "-m32 static program" '^0x1\.' $R/relocated.txt
        a "pthread_cancel (libgcc_s via the trusted dir)" '^cancelled=1' $R/relocated.txt
        n "P1: /etc/ld.so.cache never consulted" '^[1-9]' <(sed -n '/^### r.cache/,/^###/p' $R/relocated.txt | grep -E '^[0-9]+$')
        a "P2: LOCALE_ARCHIVE (no LOCPATH) finds de_DE.UTF-8" 'setlocale=de_DE.UTF-8' <(sed -n '/^### r.locale.archive/,/^###/p' $R/relocated.txt)
        a "LOCPATH wins over LOCALE_ARCHIVE" 'setlocale=de_DE.UTF-8' <(sed -n '/^### r.locale.locpath-wins/,/^###/p' $R/relocated.txt)
        a "neither: no locale data by default (dangling complocaledir)" 'setlocale=\(null\)' <(sed -n '/^### r.locale.none/,/^###/p' $R/relocated.txt)
        n "P3: /etc/ld.so.preload ignored" 'ld\.so\.preload' <(sed -n '/^### p3.ld.so.preload/,/^###/p' $R/p3.txt)
        a "P3: /etc/ld-nix.so.preload read" 'ld-nix\.so\.preload' $R/p3.txt
        a "LOCPATH mode reaches zu_ZA" '^### loc\.zu_ZA' $R/locales.txt
        cnt() { grep -c '^### loc\.' "$1" || true; }
        [ "$(cnt $R/locales.txt)" -ge 500 ] || { fails+=("LOCPATH locale count"); echo "ASSERT FAILED: LOCPATH locale count"; }
        [ "$(cnt $R/locales-archive.txt)" -ge 800 ] || { fails+=("archive locale count"); echo "ASSERT FAILED: archive locale count"; }
        echo "locales: LOCPATH $(cnt $R/locales.txt) (official langpack dirs $(cnt $out/official/locales.txt)), archive $(cnt $R/locales-archive.txt) (official $(cnt $out/official/locales-archive.txt))"
        echo "iconv: $(sed -n '/^### iconv.list/,/^###/p' $R/report.txt | sed -n 3p) charsets (official $(sed -n '/^### iconv.list/,/^###/p' $out/official/report.txt | sed -n 3p))"
      } > $out/assertions.txt
      cat $out/assertions.txt
      status=PASS
      if [ $rc -ne 0 ] || [ ''${#fails[@]} -gt 0 ]; then status=FAIL; fi
      echo "nn-${name}-runtime: $status (compare rc=$rc, ''${#fails[@]} failed assertion(s))" | tee $out/result.txt
      ${lib.optionalString failOnDiff ''
        if [ $status = FAIL ]; then
          echo "=== failed; full report: $out/compare/report.txt (build .report to keep it)" >&2
          exit 1
        fi
      ''}
    '';
  };
in
check
