# Rocky's %prep of the glibc SRPM (rpmbuild -rp in the stage0 buildroot), then
# the Nix-side patches (nix-patches/, design §4.3) checked against the result:
# each one alone with `patch -p1 --dry-run --fuzz=0`, then all of them in list
# order, then a grep that every patch did what it is for.  This is exactly the
# point where mkRpmPackage's prep hook applies them (%__spec_prep_post, in
# %{_builddir}/%{buildsubdir}).  Used by checks.nn-glibc-prep.
#
# $out is only report.txt, which is the same on every build (`nix build
# --rebuild`); rpm's own log (random rpm-tmp.* names, stdout/stderr
# interleaving) stays in /builddir and is shown only on failure.
#
#   keepTree = true: also copy the prepped, *unpatched* source tree to
#   $out/tree (for rebasing the patches; ~250 MB, never used by a check).
{ bootPkgs, lib, stage0, patches, keepTree ? false }:
let
  e = stage0.lib.fetch.entry "glibc";
  srpm = stage0.lib.fetchSrpm "glibc";
  # real files, numbered in application order
  patchDir = bootPkgs.runCommand "glibc-nix-patches" { } (''
    mkdir $out
  '' + lib.concatImapStrings (i: p: ''
    cp ${p} $out/${lib.fixedWidthNumber 2 i}-${baseNameOf (toString p)}
  '') patches);
in
stage0.lib.runInBuildroot {
  name = "glibc-prep-${e.version}-${e.release}" + lib.optionalString keepTree "-tree";
  buildroot = stage0.buildrootFull;
  binds = { "/inputs/glibc.src.rpm" = srpm; "/inputs/patches" = patchDir; };
  script = ''
    top=/builddir/build
    mkdir -p $top
    echo "=== rpmbuild -rp ${baseNameOf srpm.name}"
    rpmbuild -rp /inputs/glibc.src.rpm --nodeps --target x86_64 \
      --define "_topdir $top" --define "dist ${stage0.lib.distOf "glibc"}" \
      --define "_annotated_build 0" > /builddir/prep.log 2>&1 \
      || { tail -n 60 /builddir/prep.log; exit 1; }
    tail -n 3 /builddir/prep.log
    src=$top/BUILD/glibc-${e.version}   # %{glibcsrcdir}
    cd "$src"
    test -f elf/rtld.c
  '' + lib.optionalString keepTree ''
    cp -a "$src" /builddir/out/tree
  '' + lib.optionalString (patches == [ ]) ''
    exit 0
  '' + ''
    {
      echo "source after %prep: ''${src#$top/}"
      ok=1
      shopt -s nullglob
      for p in /inputs/patches/*.patch; do
        if patch -p1 --dry-run --fuzz=0 -i "$p" > /builddir/dry.log 2>&1; then
          echo "OK    dry-run ''${p##*/}"
        else
          echo "FAIL  dry-run ''${p##*/}"; sed 's/^/      /' /builddir/dry.log; ok=0
        fi
      done
      [ $ok = 1 ] || { echo "FAIL: a patch does not apply to Rocky's %prep result"; exit 1; }
      # all of them, in order (what the prep hook does)
      for p in /inputs/patches/*.patch; do
        patch -p1 --fuzz=0 --no-backup-if-mismatch --quiet -i "$p"
      done
      echo "OK    applied all, in order"
      # what each patch is for (design §4.2/§4.3)
      want() { if grep -qF -- "$2" "$1"; then echo "OK    $1: $2"; else echo "FAIL  $1: missing $2"; ok=0; fi; }
      want sysdeps/generic/dl-cache.h 'define LD_SO_CACHE PREFIX "/etc/ld.so.cache"'
      want elf/ldconfig.c 'define LD_SO_CONF PREFIX "/etc/ld.so.conf"'
      want elf/Makefile "PREFIX-FLAGS := -D'PREFIX=\"\$(prefix)\"'"
      want elf/rtld.c '"/etc/ld-nix.so.preload"'
      want locale/loadarchive.c 'secure_getenv ("LOCALE_ARCHIVE_2_27")'
      want locale/programs/locale.c 'secure_getenv ("LOCALE_ARCHIVE")'
      want locale/programs/locarchive.c 'secure_getenv ("LOCALE_ARCHIVE_2_27")'
      # nothing compiled into ld.so/ldconfig may still name the host cache
      if grep -rn 'SYSCONFDIR' sysdeps/generic/dl-cache.h elf/dl-cache.c elf/rtld.c elf/ldconfig.c elf/dl-usage.c elf/dl-diagnostics.c; then
        echo "FAIL  SYSCONFDIR still used by the loader/ldconfig sources above"; ok=0
      else
        echo "OK    no SYSCONFDIR left in the loader/ldconfig sources"
      fi
      [ $ok = 1 ] || exit 1
    } 2>&1 | tee /builddir/out/report.txt
    exit "''${PIPESTATUS[0]}"
  '';
}
