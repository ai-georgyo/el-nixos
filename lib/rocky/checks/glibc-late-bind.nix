# checks.nn-glibc-late-bind: mkRpmPackage's late binding (design §11.1:
# stage.pkgs.<srpm> = lateBind.wrap raw when the package declares lateBind
# and the stage binds it) on the REAL S1 glibc (rockyBoot.s1.glibc, M1).
#
# S1 does not bind (nn.stages.s1.lateBindFor = false: no Rocky bash, perl,
# python3, gd, libpng or libselinux exist yet), so rockyBoot.s1.glibc is the
# raw derivation with its named S1 exceptions (fhsAllowlist,
# allowUnresolvedNeeded).  This check runs the same mkRpmPackage over a copy
# of the S1 stage object with lateBindFor = glibc and test stand-ins:
#   interpreters  bash/sh, perl, python3: tiny wrappers that exec nixpkgs'
#                 (test-only; nothing shipped references them)
#   libs          gd, libpng, libselinux: one tree per library holding only
#                 its soname (links into the S1 glibcBuildDeps, stage0's
#                 nixpkgs-built -devel deps); zlib-ng: the real S1 package
#                 (rockyBoot.s1.zlib-ng, its compat output has libz.so.1)
# The raw derivation is the one rockyBoot.s1.glibc already is (asserted: no
# rebuild); the bind derivation copies the late outputs (common, utils,
# nss_db, benchtests) and their lateReferrers (138 langpacks, nss_devel).
#
# Eval-time: raw unchanged and unbound in S1, L* = lateBind + lateReferrers,
# untouched outputs raw, per-output rockyRequisites (an output outside L*
# never names the bind derivation or a raw L* output; a bound one names the
# stand-ins), rockyOutputsByName follows the bound outputs.
# Build-time: no raw L* output in the bound closures; every langpack symlink
# into common resolves into the bound common and a program compiled by the
# S1 glibc¹ toolchain sets a UTF-8 locale of a bound langpack whose LC_CTYPE
# links into the bound common;
# common's ldd runs through the stand-in bash and resolves the bound
# memusagestat's libgd/libpng16/libz through its new RUNPATH (the raw one
# has none: control); makedb's RUNPATH names the libselinux tree; no FHS
# shebang is left in the late outputs (the bind's own verify) and benchtests'
# python scripts point at the stand-in python3.
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  s1 = self.stages.s1;
  raw = s1.pkgs.glibc;

  wrapper = name: progs: real: pkgs.runCommand "nn-glibc-lb-${name}" { } ''
    mkdir -p $out/bin
    for p in ${toString progs}; do
      { echo '#!${pkgs.bash}/bin/bash'
        echo 'exec ${real} "$@"'; } > $out/bin/$p
      chmod +x $out/bin/$p
    done
  '';
  bashS = wrapper "bash" [ "bash" "sh" ] "${pkgs.bash}/bin/bash";
  perlS = wrapper "perl" [ "perl" ] "${pkgs.perl}/bin/perl";
  pythonS = wrapper "python3" [ "python3" ] "${pkgs.python3}/bin/python3";
  libTree = name: soname: pkgs.runCommand "nn-glibc-lb-${name}" { } ''
    mkdir -p $out/lib64
    test -e ${s1.glibcBuildDeps}/lib64/${soname}
    ln -s ${s1.glibcBuildDeps}/lib64/${soname} $out/lib64/${soname}
  '';
  gd = libTree "gd" "libgd.so.3";
  libpng = libTree "libpng" "libpng16.so.16";
  libselinux = libTree "libselinux" "libselinux.so.1";

  stageLB = s1 // {
    lateBindFor = srpm: srpm == "glibc";
    lateBindPkgs = { inherit gd libpng libselinux; };
    interpreterPkgs = { bash = bashS; sh = bashS; perl = perlS; python3 = pythonS; };
  };
  bound = self.mkRpmPackage stageLB { srpm = "glibc"; };

  ov = raw.overrides;
  late = lib.attrNames ov.lateBind;
  lstar = lib.unique (late ++ lib.concatLists (lib.attrValues ov.lateReferrers));
  rawLstar = map (o: raw.${o}) lstar;
  key = p: builtins.unsafeDiscardStringContext (toString p);
  keys = l: map key l;
  managed = lib.filter (o: o != "debug" && o != "logs") raw.outputs;
  untouched = lib.filter (o: !(lib.elem o lstar)) managed;
  langpackFr = "langpack_fr";

  tests = {
    "S1 does not bind: rockyBoot.s1.glibc is the raw derivation" =
      !(raw ? lateBound) && !(s1.lateBindFor "glibc");
    "the raw derivation is rockyBoot.s1.glibc (no rebuild)" = bound.raw.drvPath == raw.drvPath;
    "L* = lateBind outputs + lateReferrers" =
      lib.sort lib.lessThan bound.lateBound == lib.sort lib.lessThan lstar;
    "late = lateBind keys" = lib.sort lib.lessThan bound.late == lib.sort lib.lessThan late;
    "langpack_fr is a referrer of common" = lib.elem langpackFr lstar;
    "bound outputs differ from raw" = lib.all (o: key bound.${o} != key raw.${o}) lstar;
    "untouched outputs are raw" = lib.all (o: key bound.${o} == key raw.${o}) untouched;
    "out (untouched): rockyRequisites names no L* output, raw or bound" =
      let r = keys bound.out.rockyRequisites; in
      lib.all (o: !(lib.elem (key raw.${o}) r) && !(lib.elem (key bound.${o}) r)) lstar;
    "out: rockyRequisites = raw's minus the raw L* outputs" =
      keys bound.out.rockyRequisites == lib.filter (p: !(lib.elem p (keys rawLstar))) (keys raw.rockyRequisites);
    "common (bound): rockyRequisites has the bound L*, the stand-ins, no raw L*" =
      let r = keys bound.common.rockyRequisites; in
      lib.elem (key bound.common) r && lib.elem (key bound.${langpackFr}) r
      && lib.elem (key bashS) r && lib.elem (key gd) r
      && !(lib.any (p: lib.elem p r) (keys rawLstar));
    "rockyOutputsByName follows the bound outputs" =
      key bound.dev.rockyOutputsByName.common == key bound.common
      && key bound.rockyOutputsByName.out == key raw.out;
    "outputs of an untouched output see bound siblings" = key bound.dev.common == key bound.common;
    "the bind derivation's outputs are checked against raw L*" =
      bound.bound ? outputs && lib.all (o: lib.elem o bound.bound.outputs) lstar;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) tests);

  prog = pkgs.stdenvNoCC.mkDerivation {
    name = "nn-glibc-lb-locale";
    nativeBuildInputs = [ s1.ccGlibc1 ];
    strictDeps = true;
    dontUnpack = true;
    buildPhase = ''
      cat > locale.c <<'EOF'
      #include <langinfo.h>
      #include <locale.h>
      #include <stdio.h>
      int main(void) {
        if (!setlocale(LC_ALL, "")) { puts("setlocale failed"); return 1; }
        printf("%s %s\n", nl_langinfo(CODESET), nl_langinfo(DAY_1));
        return 0;
      }
      EOF
      gcc -O2 -o locale locale.c
    '';
    installPhase = "mkdir -p $out/bin; cp locale $out/bin/";
  };
in
{
  nn-glibc-late-bind = assert lib.assertMsg (failed == [ ])
    ("nn-glibc-late-bind eval tests failed: " + lib.concatStringsSep "; " failed);
  pkgs.runCommand "nn-glibc-late-bind" {
    __structuredAttrs = true;
    nativeBuildInputs = [ pkgs.python3 pkgs.binutils-unwrapped ];
    evalTests = lib.attrNames tests;
    lstar = lstar;
    bound = lib.genAttrs lstar (o: "${bound.${o}}");
    raws = lib.genAttrs lstar (o: "${raw.${o}}");
    rawOut = "${raw.out}";
    rawUtils = "${raw.utils}";
    inherit bashS pythonS gd libpng libselinux;
    zlibCompat = "${s1.pkgs.zlib-ng.compat}";
    prog = "${prog}";
    exportReferencesGraph.closure = map (o: bound.${o}) lstar;
    passthru = { inherit raw bound stageLB; };
  } ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    ok() { echo "ok: $*" | tee -a $TMPDIR/result.txt; }
    for t in "''${evalTests[@]}"; do ok "(eval) $t"; done

    # --- closures: no raw L* output; the stand-ins and raw out present
    python3 -I - "$NIX_ATTRS_JSON_FILE" <<'PY' | tee -a $TMPDIR/result.txt
    import json, sys
    a = json.load(open(sys.argv[1]))
    closure = {e["path"] for e in a["closure"]}
    bad = sorted(set(a["raws"].values()) & closure)
    assert not bad, "raw L* outputs in the bound closure: %s" % bad
    for k in ("rawOut", "bashS", "gd", "libpng", "libselinux", "zlibCompat"):
        assert a[k] in closure, "%s (%s) missing from the bound closure" % (k, a[k])
    print("ok: bound closure (%d paths) holds no raw L* output; raw out and the stand-ins present" % len(closure))
    PY

    declare -A B R
    for o in "''${lstar[@]}"; do B[$o]=''${bound[$o]}; R[$o]=''${raws[$o]}; done
    common=''${B[common]} utils=''${B[utils]}

    # --- langpack symlinks into common resolve into the bound common
    n=0
    for o in "''${lstar[@]}"; do
      case $o in langpack_*) ;; *) continue ;; esac
      while IFS= read -r l; do
        t=$(readlink "$l")
        case $t in
          ''${R[common]}/*) fail "$o: $l still points at the raw common" ;;
          $common/*) readlink -e "$l" > /dev/null || fail "$o: $l dangles"; n=$((n+1)) ;;
        esac
      done < <(find ''${B[$o]} -type l)
    done
    [ $n -gt 0 ] || fail "no langpack symlink into the bound common"
    ok "$n langpack symlinks resolve into the bound common, none into the raw one"

    # --- a glibc¹ program sets a locale whose LC_CTYPE is a link into the
    # bound common (C.utf8's), through LOCPATH = the bound langpack
    test ! -e /usr/lib/locale || fail "/usr/lib/locale exists in the sandbox (control void)"
    loc= lp=
    for o in "''${lstar[@]}"; do
      case $o in langpack_*) ;; *) continue ;; esac
      for l in ''${B[$o]}/lib/locale/*.utf8/LC_CTYPE; do
        [ -L "$l" ] || continue
        case $(readlink "$l") in $common/*) lp=''${B[$o]}; loc=$(basename "$(dirname "$l")"); break 2 ;; esac
      done
    done
    [ -n "$loc" ] || fail "no UTF-8 locale whose LC_CTYPE links into the bound common"
    got=$(LOCPATH=$lp/lib/locale LC_ALL=$loc $prog/bin/locale)
    case $got in "UTF-8 "?*) ;; *) fail "locale $loc via $lp: $got" ;; esac
    ok "$loc via the bound ''${lp##*-} (LC_CTYPE -> bound common C.utf8): $got"

    # --- common's ldd runs through the stand-in bash; memusagestat's libs bound
    [ "$(head -1 $common/bin/ldd)" = "#!$bashS/bin/bash" ] || fail "ldd shebang: $(head -1 $common/bin/ldd)"
    test ! -e /usr/bin/bash || fail "/usr/bin/bash exists in the sandbox (control void)"
    $common/bin/ldd --version > $TMPDIR/ldd-version.txt
    grep -q 'ldd (GNU libc) 2\.39' $TMPDIR/ldd-version.txt || fail "ldd --version: $(cat $TMPDIR/ldd-version.txt)"
    rp=$(readelf -d $utils/bin/memusagestat | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
    for d in $gd/lib64 $libpng/lib64 $zlibCompat/lib64; do
      case ":$rp:" in *":$d:"*) ;; *) fail "memusagestat RUNPATH $rp lacks $d" ;; esac
    done
    if readelf -d $rawUtils/bin/memusagestat | grep -q 'RUNPATH\|RPATH'; then fail "raw memusagestat has a RUNPATH (control)"; fi
    $common/bin/ldd $utils/bin/memusagestat > $TMPDIR/ldd.txt 2>&1 || true
    for s in libgd.so.3:$gd libpng16.so.16:$libpng libz.so.1:$zlibCompat; do
      grep -q "''${s%%:*} => ''${s#*:}/lib64/''${s%%:*}" $TMPDIR/ldd.txt || { cat $TMPDIR/ldd.txt; fail "ldd memusagestat: ''${s%%:*}"; }
    done
    ok "ldd (bound common, stand-in bash) resolves memusagestat's libgd/libpng16/libz through its new RUNPATH ($rp)"
    readelf -d ''${B[nss_db]}/bin/makedb | grep -q "RUNPATH.*$libselinux/lib64" || fail "makedb RUNPATH lacks libselinux"
    ok "makedb RUNPATH names the libselinux tree"

    # --- shebangs: bound to the stand-ins
    nb=0
    while IFS= read -r f; do
      h=$(head -c 200 "$f" | head -1)
      case $h in '#!/usr/'*|'#!/bin/bash'*) fail "unbound FHS shebang $h in $f" ;; esac
      case $h in "#!$pythonS/bin/python3"*) nb=$((nb+1)) ;; esac
    done < <(find ''${B[benchtests]} ''${B[utils]} $common -type f -perm -u+x)
    [ $nb -gt 0 ] || fail "no benchtests script bound to the stand-in python3"
    ok "no FHS shebang in common/utils/benchtests; $nb scripts use the stand-in python3"

    # --- reports carry no store path
    for o in common utils nss_db; do
      f=''${B[$o]}/nix-support/rocky-late-bind.json
      test -f $f || fail "$o: no rocky-late-bind.json"
      if grep -q /nix/store $f; then fail "$o: store path in the report"; fi
    done
    ok "bind reports present, no store paths"
    mkdir -p $out; cp $TMPDIR/result.txt $out/
  '';
}
