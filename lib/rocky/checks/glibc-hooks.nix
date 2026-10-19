# checks.nn-glibc-hooks: the setup hooks rocky-partition generated for
# rockyBoot.s1.glibc, used the way consumers use them -- glibc outputs as
# inputs of an ordinary stdenv build, whose setup.sh sources every input's
# nix-support/setup-hook -- and glibc's own locale tool reading the
# resulting environment (M1 review: all_langpacks' hook set LOCPATH, so
# glibc ignored its own LOCALE_ARCHIVE and every non-C locale failed; the
# alias file and C.utf8 sat in common, out of reach of libc's compiled-in
# paths).  One build per input set; each records LOCPATH / LOCALE_ARCHIVE /
# GCONV_PATH and `locale charmap` for some locales:
#   archive         [ all_langpacks ]           LOCALE_ARCHIVE, no LOCPATH;
#                                               fr_FR.UTF-8, de_DE, C.UTF-8
#   archive+dirs    [ langpack_de all_langpacks ] and the reverse order:
#                                               LOCPATH unset either way
#   dirs            [ langpack_de common ]      LOCPATH (no archive); de_DE,
#                                               alias `deutsch`, C.UTF-8
#   dev             [ dev ] (propagates out)    no GCONV_PATH (run time only);
#                                               C.UTF-8 without any variable
#                                               (complocaledir in out)
# plus: without any variable at all, `deutsch` and `C.UTF-8` resolve through
# libc's compiled-in paths (pullToPrefix: out holds locale.alias, C.utf8).
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  g = self.stages.s1.pkgs.glibc;
  locale = "${g.common}/bin/locale";

  probe = name: inputs: locales: pkgs.stdenvNoCC.mkDerivation {
    name = "nn-glibc-hooks-${name}";
    nativeBuildInputs = inputs;
    dontUnpack = true;
    __structuredAttrs = true;
    inherit locales;
    buildPhase = ''
      {
        echo "LOCPATH=''${LOCPATH-unset}"
        echo "LOCALE_ARCHIVE=''${LOCALE_ARCHIVE-unset}"
        echo "GCONV_PATH=''${GCONV_PATH-unset}"
        for l in "''${locales[@]}"; do
          echo "$l $(LC_ALL=$l ${locale} charmap 2>/dev/null)"
        done
      } | sed -E 's,/nix/store/[a-z0-9]{32}-,/nix/store/<h>-,g' > result.txt
      cat result.txt
    '';
    installPhase = "mkdir -p $out; cp result.txt $out/";
  };

  la = g.all_langpacks;
  de = g.langpack_de;
  probes = {
    archive = probe "archive" [ la ] [ "fr_FR.UTF-8" "de_DE.UTF-8" "C.UTF-8" ];
    archive-dirs = probe "archive-dirs" [ de la ] [ "de_DE.UTF-8" "C.UTF-8" ];
    dirs-archive = probe "dirs-archive" [ la de ] [ "de_DE.UTF-8" "C.UTF-8" ];
    dirs = probe "dirs" [ de g.common ] [ "de_DE.UTF-8" "deutsch" "C.UTF-8" "fr_FR.UTF-8" ];
    dev = probe "dev" [ g.dev ] [ "C.UTF-8" ];
  };
in
{
  nn-glibc-hooks = pkgs.runCommand "nn-glibc-hooks" ({
    __structuredAttrs = true;
    lsuffix = lib.removePrefix "${builtins.storeDir}/" "${la}";
    dsuffix = lib.removePrefix "${builtins.storeDir}/" "${de}";
    csuffix = lib.removePrefix "${builtins.storeDir}/" "${g.common}";
    osuffix = lib.removePrefix "${builtins.storeDir}/" "${g.out}";
    probes = lib.mapAttrs (_: p: "${p}") probes;
    passthru = { inherit probes; };
  }) ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    ok() { echo "ok: $*" | tee -a $TMPDIR/result.txt; }
    n() { echo "/nix/store/<h>-''${1#*-}"; }      # store path -> normalised form
    L=$(n $lsuffix) D=$(n $dsuffix)
    r() { cat ''${probes[$1]}/result.txt; }
    has() { grep -qxF -- "$2" <<<"$(r $1)" || { r $1; fail "$1: no line '$2'"; }; }

    for p in archive archive-dirs dirs-archive; do
      has $p "LOCPATH=unset"
      has $p "LOCALE_ARCHIVE=$L/lib/locale/locale-archive"
      has $p "de_DE.UTF-8 UTF-8"
      has $p "C.UTF-8 UTF-8"
    done
    has archive "fr_FR.UTF-8 UTF-8"
    ok "all_langpacks: LOCALE_ARCHIVE set, LOCPATH unset (alone and with langpack_de, either order); fr_FR/de_DE/C.UTF-8 resolve"

    has dirs "LOCALE_ARCHIVE=unset"
    case $(r dirs | sed -n 's/^LOCPATH=//p') in
      *"$D/lib/locale"*) ;; *) r dirs; fail "dirs: LOCPATH lacks langpack_de" ;;
    esac
    has dirs "de_DE.UTF-8 UTF-8"
    has dirs "deutsch ISO-8859-1"
    has dirs "C.UTF-8 UTF-8"
    has dirs "fr_FR.UTF-8 ANSI_X3.4-1968"
    ok "langpack_de + common: LOCPATH (no archive); de_DE, the alias deutsch, C.UTF-8 resolve; fr_FR (not installed) does not"

    has dev "GCONV_PATH=unset"
    has dev "C.UTF-8 UTF-8"
    ok "dev (+ out): no GCONV_PATH (run time only), C.UTF-8 resolves"

    # no variables at all: libc's compiled-in alias file and complocaledir
    # (out, pullToPrefix) -- the alias needs a locale, so LOCPATH = langpack_de
    gout=$NIX_STORE/$osuffix lp=$NIX_STORE/$dsuffix/lib/locale
    test -f $gout/share/locale/locale.alias && test ! -L $gout/share/locale/locale.alias || fail "locale.alias not in out"
    test -f $gout/lib/locale/C.utf8/LC_CTYPE || fail "C.utf8 not in out"
    [ "$(readlink $NIX_STORE/$csuffix/share/locale/locale.alias)" = $gout/share/locale/locale.alias ] || fail "common's locale.alias is not a link to out's"
    [ "$(env -i LC_ALL=C.UTF-8 ${locale} charmap 2>/dev/null)" = UTF-8 ] || fail "C.UTF-8 without LOCPATH/LOCALE_ARCHIVE"
    [ "$(env -i LOCPATH=$lp LC_ALL=deutsch ${locale} charmap 2>/dev/null)" = ISO-8859-1 ] || fail "deutsch via langpack_de"
    [ "$(env -i LOCPATH=$lp LC_ALL=norwegian ${locale} charmap 2>/dev/null)" = ANSI_X3.4-1968 ] || fail "norwegian should need langpack_nb"
    ok "compiled-in paths: C.UTF-8 with no variable; alias deutsch (langpack_de via LOCPATH) -> ISO-8859-1"
    mkdir -p $out; cp $TMPDIR/result.txt $out/
  '';
}
