# Lock generator helpers (docs/nix-native-design.md §3.2, §8.2).
#
#   nn.lockgen.subpackages.<srpm>   `rpmspec -q` of the exact locked SRPM in the
#                                   lockgen buildroot -> one JSON file
#                                   (lib/rocky/lockgen/raw2json.py documents it)
#   nn.lockgen.paths                { <srpm> = { drv; out; }; } for the collector
#   nn.lockgen.seed                 SRPM names the lock must always cover
#   nn.lockgen.buildroot            stage0-full + the *-rpm-macros subpackages
#                                   + macros.rust-srpm
#   nn.lockgen.rustSrpmMacros       macros.rust-srpm from the locked rust SRPM
#
# tools/lock_subpackages.py builds these (incrementally: every result is an
# ordinary cached derivation) and folds them into lock/rocky-<rel>/subpackages.json.
# Nothing here is read at evaluation time by package builds (no IFD).
{ bootPkgs, lib, lock, fetch, stage0, ... }:
let
  pkgs = bootPkgs;
  l0 = stage0.lib;

  # rpmspec runs with the stage0 rpm 4.19.1.1 and Rocky's macro packages:
  # stage0-full has redhat-rpm-config + every *-srpm-macros (what Koji's
  # buildsrpm root has); the *-rpm-macros subpackages that the same stage0
  # builds produce are added, because some of them create subpackages at parse
  # time (%pyproject_extras_subpkg, %python_extras_subpkg) or are used in
  # %package lines.  --nodeps --noscripts, as everywhere in stage0.
  # redhat-rpm-config also Requires rust-srpm-macros (%rust_arches, used in
  # ExclusiveArch); see rustSrpmMacros.
  buildroot = l0.mkBuildroot {
    name = "lockgen";
    base = stage0.buildrootFull;
    rpms = [
      { from = stage0.srpm.python-rpm-macros; names = [ "python-rpm-macros" "python3-rpm-macros" ]; }
      { from = stage0.srpm.pyproject-rpm-macros; names = [ "pyproject-rpm-macros" ]; }
      { from = stage0.srpm.kernel-srpm-macros; names = [ "kernel-rpm-macros" ]; }
      { from = stage0.srpm.fonts-rpm-macros; names = [ "fonts-rpm-macros" "fonts-filesystem" ]; }
      { from = stage0.srpm.lua-rpm-macros; names = [ "lua-rpm-macros" ]; }
      { from = stage0.srpm.qt6; names = [ "qt6-rpm-macros" ]; }
    ];
    extraCommands = ''
      install -D -m 644 ${rustSrpmMacros} "$BUILDROOT/usr/lib/rpm/macros.d/macros.rust-srpm"
    '';
  };

  # rust-srpm-macros: in Rocky 10 rust-toolset-srpm-macros of the 270 MB rust
  # SRPM provides it, and stage0 does not build rust (docs/stage0.md).  Its
  # %files is the one macro file, installed verbatim from Source101
  # (`%{__install} -D -m 644 %{S:101} %{buildroot}%{rpmmacrodir}/macros.rust-srpm`),
  # so the lock generator takes that source straight from the locked SRPM.
  # (Not registered in the rpmdb: rpmspec -q only needs the macros.)
  rustSrpmMacros = pkgs.runCommand "macros.rust-srpm-${lock.srpms.rust.version}-${lock.srpms.rust.release}"
    { nativeBuildInputs = [ pkgs.libarchive pkgs.gnugrep ]; } ''
    bsdtar -xOf ${fetch.fetchSrpm "rust"} rust.spec > rust.spec
    grep -Eq '^Source101:[[:space:]]+macros\.rust-srpm$' rust.spec
    grep -Fq '%{S:101} %{buildroot}%{rpmmacrodir}/macros.rust-srpm' rust.spec
    bsdtar -xOf ${fetch.fetchSrpm "rust"} macros.rust-srpm > $out
    grep -q '^%rust_arches ' $out
  '';

  runnerTools = with pkgs; [ bubblewrap coreutils findutils gnugrep gnused gawk diffutils attr cpio bash ];
  queryScript = ../lockgen/rpmspec-query.sh;
  raw2json = ../lockgen/raw2json.py;

  evrOf = e: lib.optionalString (e.epoch != 0) "${toString e.epoch}:" + "${e.version}-${e.release}";

  query = name:
    let
      e = lock.srpms.${name};
      src = fetch.fetchSrpm name;
      dist = l0.distOf name; # -> %distcore (see rpmspec-query.sh)
    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "lockgen-subpackages-${name}-${e.version}-${e.release}.json";
      nativeBuildInputs = runnerTools ++ [ pkgs.python3 ];
      buildCommand = ''
        set -euo pipefail
        source ${l0.chrootLib}
        chroot_setup $TMPDIR/st ${lib.escapeShellArgs buildroot.layers}
        mkdir -p $TMPDIR/builddir
        cp ${queryScript} $TMPDIR/builddir/query.sh
        # the SRPM is read straight from the (read-only) store
        chroot_exec --user 1000 135 --store --bind $TMPDIR/builddir /builddir --chdir /builddir \
          --setenv USER mockbuild --setenv LOGNAME mockbuild \
          -- /bin/bash /builddir/query.sh ${src} ${lib.escapeShellArg dist}
        python3 -I ${raw2json} $TMPDIR/builddir/out ${lib.escapeShellArg name} \
          ${lib.escapeShellArg (evrOf e)} ${lib.escapeShellArg dist} > $out
        cat $out
      '';
      allowedReferences = [ ];
      passthru = { srpmName = name; inherit src; };
    };

  subpackages = lib.mapAttrs (name: _: query name) lock.srpms;
in
{
  inherit buildroot subpackages rustSrpmMacros;
  paths = lib.mapAttrs (_: d: { drv = d.drvPath; out = d.outPath; }) subpackages;

  # Always covered (design §12 WP1): the S1/S2 toolchain set, glibc's
  # neighbours, and the stage0 macro SRPMs (+ rust, which ships
  # rust-srpm-macros, the one macro package stage0 lacks; see rustSrpmMacros).
  seed = [
    "glibc" "kernel" "which" "xz" "gzip" "sed" "m4" "expat" "libxcrypt" "ncurses" "krb5"
    "zlib-ng" "zstd" "gmp" "mpfr" "libmpc" "binutils" "gcc" "bash" "coreutils"
    "rocky-release" "redhat-rpm-config" "efi-rpm-macros" "fonts-rpm-macros"
    "forge-srpm-macros" "go-rpm-macros" "kernel-srpm-macros" "lua-rpm-macros"
    "ocaml-srpm-macros" "openblas-srpm-macros" "package-notes" "perl-srpm-macros"
    "pyproject-rpm-macros" "python-rpm-macros" "qt6" "rust"
  ];
}
