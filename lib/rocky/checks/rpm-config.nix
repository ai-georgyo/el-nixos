# checks.nn-rpm-config: the relocation rpm config (lib/rocky/rpm), in a
# plain bwrap shim (/usr/bin = stage0 rpm + bootstrap tools, /usr/lib/rpm =
# the instantiated config; the real tool shim is lib/rocky/tool-shim.sh):
#   - rpm --eval of every macro of docs/nix-native-design.md §1.2 against a
#     sample prefix, the macro path order, %optflags/%dist/%configure
#   - a full macro audit (Rocky config vs relocated) -> $out/macro-audit.tsv
#   - fold-usr, check-files, prep-hooks and config.site unit tests
#   - rpmbuild -bb of two tiny specs (lib/rocky/rpm/tests/*.spec) with
#     %_prefix = a fake /nix/store path: the RPM file lists carry the
#     relocated paths, nothing is reported unpackaged
# Results: $out/results.txt (one line per assertion), rpmbuild logs.
{ bootPkgs, lib, stage0, self, ... }:
let
  pkgs = bootPkgs;
  # a macro package laid out like a relocated build (%_rpmmacrodir = $out/lib/rpm/macros.d)
  relocatedMacroPkg = pkgs.runCommand "nn-test-relocated-macros" { } ''
    mkdir -p $out/lib/rpm/macros.d
    echo '%nn_relocated_macro_pkg %{_datadir}/nn' > $out/lib/rpm/macros.d/macros.nn-test
  '';
  cfg = self.rpmConfig { macroPkgs = [ relocatedMacroPkg ]; extraMacroDirs = [ ../rpm/tests/macros.d ]; };
  tests = lib.fileset.toSource { root = ../rpm/tests; fileset = ../rpm/tests; };
  # what the shim's /usr/bin holds (bootstrap tools only; first wins)
  farm = pkgs.runCommand "nn-rpm-config-test-farm" { } ''
    mkdir -p $out/bin
    # brp-ldconfig runs /sbin/ldconfig -N -r BUILDROOT: Rocky's (stage0, static)
    ln -s ${stage0.glibc}/usr/sbin/ldconfig $out/bin/ldconfig
    for d in ${stage0.rpm}/usr ${lib.concatMapStringsSep " " (p: "${lib.getBin p}") (with pkgs; [
               bash coreutils gnused gnugrep gawk findutils diffutils gnupatch gnutar gzip bzip2
               xz zstd cpio file binutils-unwrapped which util-linux ])}; do
      for x in $d/bin/*; do
        n=''${x##*/}; [ -e $out/bin/$n ] || ln -s $x $out/bin/$n
      done
    done
  '';
in
{
  nn-rpm-config = pkgs.runCommand "nn-rpm-config" {
    nativeBuildInputs = with pkgs; [ bubblewrap bash coreutils gnused gnugrep gawk findutils diffutils gnupatch ];
    inherit cfg farm tests;
    configSite = cfg.configSite;
  } ''
    bash ${tests}/rpm-config-test.sh
  '';
}
