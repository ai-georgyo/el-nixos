# checks.nn-rpm-config: the relocation rpm config (lib/rocky/rpm), in a
# plain bwrap shim (/usr/bin = stage0 rpm + bootstrap tools, /usr/lib/rpm =
# the instantiated config; the real tool shim is lib/rocky/tool-shim.sh):
#   - rpm --eval of every macro of docs/nix-native-design.md §1.2 against a
#     sample prefix, the macro path order, %optflags/%dist/%configure
#   - Rocky's real systemd-rpm-macros (the locked RPM): its directory macros
#     follow the prefix; without it they stay undefined
#   - a relocated rpm (lib/rpm, its own store path in platform/*/macros)
#   - a full macro audit (Rocky config vs relocated) -> $out/macro-audit.tsv
#   - fold-usr, check-files, prep-hooks and config.site unit tests
#   - rpmbuild -bb of two tiny specs (lib/rocky/rpm/tests/*.spec) with
#     %_prefix = a fake /nix/store path: the RPM file lists carry the
#     relocated paths, nothing is reported unpackaged, BUILDTIME follows the
#     changelog only with SOURCE_DATE_EPOCH unset
# Results: $out/results.txt (one line per assertion), rpmbuild logs.
{ bootPkgs, lib, stage0, fetch, self, ... }:
let
  pkgs = bootPkgs;
  # a macro package laid out like a relocated build (%_rpmmacrodir = $out/lib/rpm/macros.d)
  relocatedMacroPkg = pkgs.runCommand "nn-test-relocated-macros" { } ''
    mkdir -p $out/lib/rpm/macros.d
    echo '%nn_relocated_macro_pkg %{_datadir}/nn' > $out/lib/rpm/macros.d/macros.nn-test
  '';
  # Rocky's systemd-rpm-macros (not in stage0), unpacked from the official
  # RPM in the lock (test data only: an FHS usr/lib/rpm macro package)
  systemdRpmMacros = pkgs.runCommand "nn-test-systemd-rpm-macros" {
    nativeBuildInputs = [ pkgs.cpio ];
    rpmFile = fetch.fetchRpm "systemd-rpm-macros.noarch";
  } ''
    mkdir -p $out
    RPM_CONFIGDIR=${stage0.rpm}/usr/lib/rpm ${stage0.rpm}/usr/bin/rpm2cpio $rpmFile \
      | (cd $out && cpio -idm --quiet --no-absolute-filenames)
    test -f $out/usr/lib/rpm/macros.d/macros.systemd
  '';
  # an rpm laid out like a relocated build: lib/rpm, and platform/*/macros
  # with `%_prefix <its own $out>` as rpm's installplatform writes it
  relocatedRpm = pkgs.runCommand "nn-test-relocated-rpm" { } ''
    mkdir -p $out/lib
    cp -RP ${stage0.rpm}/usr/lib/rpm $out/lib/rpm
    chmod -R u+w $out/lib/rpm
    sed -i "s|^%_prefix.*|%_prefix\t$out|" $out/lib/rpm/platform/x86_64-linux/macros
    grep -q "^%_prefix.$out\$" $out/lib/rpm/platform/x86_64-linux/macros
  '';
  cfg = self.rpmConfig {
    macroPkgs = [ relocatedMacroPkg systemdRpmMacros ];
    extraMacroDirs = [ ../rpm/tests/macros.d ];
  };
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
    # Rocky's config without systemd-rpm-macros; one around a relocated rpm
    cfgPlain = self.rpmConfig;
    cfgRelocRpm = self.rpmConfig { rpm = relocatedRpm; };
    configSite = cfg.configSite;
  } ''
    bash ${tests}/rpm-config-test.sh
  '';
}
