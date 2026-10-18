# rpmConfig: an /usr/lib/rpm-style rpm configuration dir for relocated builds
# (docs/nix-native-design.md §1.2, §5.5).  $out is what the tool shim mounts
# at /usr/lib/rpm:
#   rpm's own lib/rpm             macros, rpmrc, platform/, fileattrs/, brp-*,
#                                 check-*, rpmdeps, elfdeps, lua/ ...
#   + every macro package's lib/rpm (redhat-rpm-config: redhat/, macros.d/,
#     fileattrs/; *-srpm-macros/*-rpm-macros: macros.d/; rocky-release:
#     macros.d/macros.dist)
#   + extraMacroDirs              plain directories of macro files -> macros.d/
#   + nix/                        macros.nix-reloc (template) and the helper
#                                 scripts fold-usr, check-files, prep-hooks,
#                                 instantiate
# Packages may be FHS trees (stage0: usr/lib/rpm) or relocated store paths
# (lib/rpm, where %_rpmmacrodir puts macro files); both are looked up.  Two
# sources providing the same file with different contents is an error.
#
# The result is NOT usable for rpmbuild as is: per build,
#   sh $rpmConfig/nix/instantiate DEST --prefix $out --buildtop $NIX_BUILD_TOP \
#     --ncpus $NIX_BUILD_CORES [--dist .el10_2] [--macro-dir DIR]...
# makes a writable copy with the relocation macros substituted and appended
# to redhat/macros (read after macros.d and the platform file).  Unchanged,
# it is plain Rocky configuration (fine for rpm -qp / rpmspec -q).
#
# Usage: rpmConfig { rpm ? stage0.rpm, macroPkgs ? [ ], extraMacroDirs ? [ ],
#                    baseMacroPkgs ? <stage0's redhat-rpm-config, *-srpm-macros,
#                    rocky-release> }
# `rpmConfig` itself is the default instance (buildable, and callable).
{ bootPkgs, lib, stage0, ... }:
let
  # the macro packages of a Rocky buildroot that stage0 has (bootstrap/default.nix
  # macroSrpms; rust-srpm-macros and systemd-rpm-macros are not in stage0)
  stage0MacroPkgs = with stage0.rpms; [
    redhat-rpm-config rocky-release
    efi-srpm-macros fonts-srpm-macros forge-srpm-macros go-srpm-macros kernel-srpm-macros
    lua-srpm-macros ocaml-srpm-macros openblas-srpm-macros package-notes-srpm-macros
    perl-srpm-macros pyproject-srpm-macros python-srpm-macros qt6-srpm-macros
  ];

  # generic CONFIG_SITE fragment for relocated autoconf builds (§1.3)
  configSite = ../config.site;

  scripts = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./macros.nix-reloc ./nix-scripts ];
  };

  mkConfig = { rpm ? stage0.rpm, macroPkgs ? [ ], extraMacroDirs ? [ ], baseMacroPkgs ? stage0MacroPkgs }:
    bootPkgs.runCommand "rocky-rpm-config" {
      pkgs = baseMacroPkgs ++ macroPkgs;
      macroDirs = extraMacroDirs;
      passthru = { inherit rpm configSite; instantiate = "nix/instantiate"; };
    } ''
      set -euo pipefail
      mkdir -p $out
      # rpm itself: FHS (stage0) or relocated
      if [ -d ${rpm}/usr/lib/rpm ]; then rpmdir=${rpm}/usr/lib/rpm
      elif [ -d ${rpm}/lib/rpm ]; then rpmdir=${rpm}/lib/rpm
      else echo "no lib/rpm in ${rpm}" >&2; exit 1; fi
      cp -RP $rpmdir/. $out/
      chmod -R u+w $out
      test -f $out/macros && test -f $out/rpmrc && test -d $out/platform

      # add tree $1 to $out (relative paths kept), identical duplicates allowed
      add() {
        (cd "$1" && find . ! -type d) | while IFS= read -r f; do
          if [ -e "$out/$f" ] || [ -L "$out/$f" ]; then
            if [ -L "$1/$f" ] && [ -L "$out/$f" ] && [ "$(readlink "$1/$f")" = "$(readlink "$out/$f")" ]; then continue; fi
            if [ ! -L "$1/$f" ] && [ ! -L "$out/$f" ] && cmp -s "$1/$f" "$out/$f"; then continue; fi
            echo "rpm config: $2 provides ''${f#./} with different contents" >&2; exit 1
          fi
          mkdir -p "$(dirname "$out/$f")"
          cp -P "$1/$f" "$out/$f"
          chmod u+w "$out/$f" 2>/dev/null || true
        done
      }
      for p in $pkgs; do
        n=0
        for d in $p/usr/lib/rpm $p/lib/rpm; do
          if [ -d $d ]; then add $d $p; n=1; fi
        done
        [ $n -eq 1 ] || { echo "rpm config: $p has no lib/rpm" >&2; exit 1; }
      done
      mkdir -p $out/macros.d
      for d in $macroDirs; do
        [ -d $d ] || { echo "rpm config: $d is not a directory" >&2; exit 1; }
        rm -rf $TMPDIR/md; mkdir -p $TMPDIR/md/macros.d
        for f in $d/*; do if [ -f $f ]; then cp $f $TMPDIR/md/macros.d/; fi; done
        add $TMPDIR/md $d
      done

      mkdir -p $out/nix
      cp ${scripts}/macros.nix-reloc $out/nix/
      for s in fold-usr check-files prep-hooks instantiate; do
        cp ${scripts}/nix-scripts/$s $out/nix/$s
        chmod 0755 $out/nix/$s
      done
      # the macro/script layer must be FHS-clean (shebangs, tool paths): the
      # copied ELF helpers (rpmdeps, elfdeps, ...) may reference their libraries
      if grep -rlI /nix/store $out; then
        echo "store paths in the rpm config's text files" >&2; exit 1
      fi
    '';
in
mkConfig { } // {
  __functor = _: mkConfig;
  inherit stage0MacroPkgs configSite;
}
