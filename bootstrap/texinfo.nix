# texinfo 7.1 from Rocky's texinfo SRPM (tarball + all patches of texinfo.spec),
# built with nixpkgs' texinfo recipe.  nixpkgs only has 7.2, whose makeinfo
# output differs from Rocky's 7.1 (version banner, index sort order, sentence
# spacing), which made every glibc-doc info page differ (docs/glibc.md).
# Exposed as an FHS tree (usr/bin/{makeinfo,texi2any,...} -> store) for a
# package root; the root's "first provider wins" puts it ahead of nixpkgs'
# texinfo.  Not part of the stage0 base root (the toolchain does not use it).
{ pkgs, srpm
  # Rocky's glibc buildroot has no perl-Unicode-Collate (it is not in the
  # mock-resolved closure, docs/research/glibc-buildroot-closure.md), so
  # Rocky's texi2any falls back to its Texinfo::CollateStub and sorts index
  # entries by code point ("(" and ":" before "_").  nixpkgs' perl has
  # Unicode::Collate, which sorts punctuation differently (UCA).  true: hide
  # it from makeinfo, as in Rocky's buildroot.
, withoutUnicodeCollate ? true
}:
let
  inherit (pkgs) lib;
  e = srpm.lockEntry;
  # texinfo.spec: Patch0..Patch4, %autopatch -p1
  patchNames = [
    "info-6.5-sync-fix-info-dir.patch"
    "texinfo-6.5-fix-info-dir.patch"
    "texinfo-6.5-covscan-fixes.patch"
    "texinfo-7.1-various-sast-fixes.patch"
    "texinfo-7.1-make-tainted-data-safe.patch"
  ];
  texinfo = pkgs.texinfo.overrideAttrs (o: {
    pname = "stage0-texinfo";
    version = "${e.version}-${e.release}";
    src = "${srpm}/texinfo-${e.version}.tar.xz";
    # %prep: `install -Dpm0755 -t contrib %{SOURCE2}` before %autopatch
    # (Patch0 edits contrib/fix-info-dir)
    prePatch = (o.prePatch or "") + ''
      install -Dpm0755 -t contrib ${srpm}/fix-info-dir
    '';
    patches = map (p: "${srpm}/${p}") patchNames;
    # texinfo.spec: --disable-perl-xs (pure-perl parser, like Rocky's makeinfo)
    configureFlags = (o.configureFlags or [ ]) ++ [ "--disable-perl-xs" ];
    doCheck = false;
    # the patches touch install-info.c, so its man page is regenerated
    # (texinfo.spec BuildRequires help2man too)
    nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ pkgs.help2man ];
    # 7.1's C helpers (install-info, info) predate C23 (nixpkgs gcc defaults to it)
    env = (o.env or { }) // { NIX_CFLAGS_COMPILE = "-std=gnu17"; };
  });
in
pkgs.runCommand "stage0-texinfo-tree-${e.version}-${e.release}" { passthru = { inherit texinfo; }; } (''
  mkdir -p $out/usr/bin
'' + (if withoutUnicodeCollate then ''
  # a Unicode/Collate.pm that fails to load, first in @INC for these tools only
  mkdir -p $out/share/no-unicode-collate/Unicode
  echo 'die "Unicode::Collate is not installed (as in Rocky'"'"'s glibc buildroot)\n";' \
    > $out/share/no-unicode-collate/Unicode/Collate.pm
  for f in ${texinfo}/bin/*; do
    n=$(basename $f)
    if head -c 100 $f | grep -q perl; then
      printf '#!/usr/bin/sh\nPERL5LIB=%s''${PERL5LIB:+:$PERL5LIB} exec %s "$@"\n' \
        $out/share/no-unicode-collate $f > $out/usr/bin/$n
      chmod 0755 $out/usr/bin/$n
    else
      ln -s $f $out/usr/bin/$n
    fi
  done
'' else ''
  for f in ${texinfo}/bin/*; do ln -s $f $out/usr/bin/$(basename $f); done
'') + ''
  ${texinfo}/bin/makeinfo --version | head -1 | grep -qx 'texi2any (GNU texinfo) ${e.version}'
'')
