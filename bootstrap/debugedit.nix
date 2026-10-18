# stage0 debugedit (find-debuginfo, debugedit, sepdebugcrcfix): Rocky's
# debugedit-5.1 tarball + its 6 patches, as debugedit.spec builds it, with
# FHS paths compiled in (prefix /usr; find-debuginfo calls the tools by name
# from PATH, i.e. /usr/bin inside the chroot).  Host binaries link nixpkgs
# elfutils/xxhash (store RUNPATH; fine in stage0).
{ pkgs, srpm }:
let e = srpm.lockEntry; in
pkgs.stdenv.mkDerivation {
  pname = "stage0-debugedit";
  version = "${e.version}-${e.release}";
  src = "${srpm}/debugedit-${e.version}.tar.xz";
  patches = map (p: "${srpm}/${p}") [
    "0001-find-debuginfo-Check-files-are-writable-before-modif.patch"
    "0001-find-debuginfo-Fix-skip_mini-.gnu_debugdata-handling.patch"
    "0001-find-debuginfo-Make-return-from-do_file-explicit.patch"
    "debugedit-5.1-binutils-tools-override.patch"
    "0001-debugedit-Handle-unused-.debug_str_offsets-entries.patch"
    "0001-Add-basic-find-debuginfo-script-tests.patch"
  ];
  # help2man runs scripts/find-debuginfo --help at build time; the installed
  # script gets its FHS shebang back in postInstall
  postPatch = "patchShebangs scripts";
  nativeBuildInputs = with pkgs; [ autoreconfHook pkg-config help2man ];
  buildInputs = with pkgs; [ elfutils xxhash ];
  configurePlatforms = [ ];
  dontAddPrefix = true;
  configureFlags = [ "--prefix=/usr" "--libdir=/usr/lib64" "--mandir=/usr/share/man" ];
  installFlags = [ "DESTDIR=$(out)" ];
  postInstall = ''
    ln -s find-debuginfo $out/usr/bin/find-debuginfo.sh
    sed -i '1s|^#!.*bash|#!/usr/bin/bash|' $out/usr/bin/find-debuginfo
    head -1 $out/usr/bin/find-debuginfo
    ! grep -n /nix/store $out/usr/bin/find-debuginfo
  '';
  dontPatchShebangs = true;
  dontPatchELF = true;
}
