# stage0 rpm: Rocky's rpm-4.19.1.1 + every patch of rpm.spec's %patchlist,
# configured like rpm.spec (RPM_VENDOR=redhat, sqlite+ndb backends, dbpath
# /usr/lib/sysimage/rpm), built against nixpkgs libraries.
#
# Why not nixpkgs' rpm 4.20: 4.20 moved the build tree to
# %{_builddir}/%{NAME}-%{VERSION}-build/, changed %prep/%setup semantics and
# the debugsource layout -- packages built with it would differ from Rocky's.
# Building the exact rpm Rocky builds with keeps rpmbuild behaviour identical.
#
# Layout of $out:
#   usr/bin/{rpm,rpmbuild,...}   host binaries, RUNPATH -> $out/usr/lib64 + nixpkgs libs
#   usr/lib64/librpm*.so*        rpm's libraries (deliberately NOT exposed at
#                                /usr/lib64 in the buildroot: they are nixpkgs-
#                                linked and must not shadow Rocky's rpm-libs)
#   usr/lib/rpm/                 %_rpmconfigdir content (macros, rpmrc, platform/,
#                                fileattrs/, brp scripts, rpmdeps, elfdeps, ...)
# Every path compiled into the binaries and macros is the FHS one
# (/usr/lib/rpm, /etc/rpm, /var, /usr/bin/<tool>), so it behaves inside the
# chroot exactly like Rocky's rpm.
{ pkgs, srpm }:
let
  e = srpm.lockEntry;
  patches = [
    "rpm-4.17.x-rpm_dbpath.patch" "rpm-4.18.x-siteconfig.patch" "rpm-4.9.90-no-man-dirs.patch"
    "rpm-4.18.92-disable-sysusers.patch" "rpm-4.18.90-weak-user-group.patch"
    "0001-Fix-potential-use-of-uninitialized-pipe-array.patch"
    "0001-Fix-potential-use-of-uninitialized-pgp-struct.patch"
    "0001-Fix-memory-leak-in-rpmsign.patch"
    "0001-Refactor-sign-command-expand-and-parse-out-of-runGPG.patch"
    "0002-Eliminate-hardcoded-GPG-references-from-user-visible.patch"
    "0003-Declare-signCmd-static.patch"
    "0001-Report-unsafe-symlinks-during-installation-as-a-spec.patch"
    "0002-Fix-FA_TOUCH-ed-files-getting-removed-on-failed-upda.patch"
    "0001-Fix-possible-package-corruption-on-delsign-resign-ad.patch"
    "0002-Fix-regression-on-build-id-generation-from-compresse.patch"
    "0003-Fix-root-relocation-regression.patch"
    "0001-Make-_passwd_path-and-_group_path-lists.patch"
    "0002-Fix-memory-leak-in-rpmspec-shell.patch"
    "0003-Fix-memory-leak-in-runGPG.patch"
    "0004-Talk-about-rpmsign-in-the-rpmsign-man-page.patch"
    "0005-Revert-Drop-redundant-argument-from-rpmcliTransactio.patch"
    "0001-Store-configurable-digest-s-on-packages-from-verific.patch"
    "0001-Ensure-binary-and-source-headers-are-identified-as-s.patch"
    "0002-Add-support-for-spec-local-file-attributes-and-gener.patch"
    "rpm-4.19.x-rpmkeys-add-list-erase.patch"
    "rpm-4.19.x-multisig.patch" "rpm-4.19.x-pqc-algo.patch" "rpm-4.19.x-pqc-fixes.patch"
    "0001-Really-allow-qualifiers-like-pre-post-meta-for-weak-.patch"
    "rpm-4.19.x-multisig-verify-fixes.patch" "rpm-4.19.x-nsswitch-enable.patch"
    "0001-Fix-empty-password-field-in-passwd-group-causing-ent.patch"
    "rpm-4.7.1-geode-i686.patch"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "stage0-rpm";
  version = "${e.version}-${e.release}";
  src = "${srpm}/rpm-${e.version}.tar.bz2";
  patches = map (p: "${srpm}/${p}") patches;

  nativeBuildInputs = with pkgs; [ cmake pkg-config patchelf gettext ];
  buildInputs = with pkgs; [
    zlib bzip2 xz zstd popt file lua5_4 libarchive sqlite elfutils
    libcap acl readline ncurses rpm-sequoia
  ];

  # build-time helper only (generates usr/lib/rpm/platform/*); not installed.
  # Without this it silently fails: there is no /usr/bin/env in the sandbox.
  postPatch = ''
    patchShebangs installplatform
  '';

  dontUseCmakeConfigure = true;
  configurePhase = ''
    runHook preConfigure
    mkdir _build && cd _build
    # Every helper tool path in the generated macros must be the FHS one:
    # rpm's findutil() only searches $MYPATH and /usr/bin,/bin,... -- unset
    # MYPATH so all of them resolve to /usr/bin/<tool> like on Rocky.
    unset MYPATH
    cmake .. \
      -DCMAKE_BUILD_TYPE=None \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib64 \
      -DCMAKE_INSTALL_SYSCONFDIR=/etc \
      -DCMAKE_INSTALL_LOCALSTATEDIR=/var \
      -DCMAKE_INSTALL_SHAREDSTATEDIR:PATH=/var/lib \
      -DRPM_CONFIGDIR=/usr/lib/rpm \
      -DRPM_VENDOR=redhat \
      -D__FIND_DEBUGINFO=/usr/bin/find-debuginfo \
      -DENABLE_NDB=ON -DENABLE_SQLITE=ON -DENABLE_BDB_RO=OFF \
      -DWITH_SEQUOIA=ON \
      -DENABLE_PYTHON=OFF -DENABLE_PLUGINS=OFF -DENABLE_TESTSUITE=OFF -DENABLE_NLS=OFF \
      -DWITH_SELINUX=OFF -DWITH_DBUS=OFF -DWITH_AUDIT=OFF -DWITH_FAPOLICYD=OFF \
      -DWITH_IMAEVM=OFF -DWITH_FSVERITY=OFF \
      -DCMAKE_SKIP_BUILD_RPATH=ON
    runHook postConfigure
  '';

  enableParallelBuilding = true;
  installFlags = [ "DESTDIR=$(out)" ];

  postInstall = ''
    cd $out
    mkdir -p usr/lib/rpm/macros.d etc/rpm usr/lib/sysimage/rpm
    ln -s ../../bin/find-debuginfo usr/lib/rpm/find-debuginfo.sh
    # as rpm.spec: these live in perl-generators / python-rpm-generators now
    rm -f usr/lib/rpm/{perldeps.pl,perl.*,pythond*} usr/lib/rpm/fileattrs/{perl*,python*}
    rm -f usr/lib/rpm/rpmdump
    rm -rf var/tmp
    test -f usr/lib/rpm/platform/x86_64-linux/macros   # installplatform ran
    # what redhat-rpm-config's brp-mangle-shebangs does to Rocky's rpm package
    for f in $(find usr/lib/rpm -type f); do
      if head -c 7 "$f" | grep -q '^#!/bin/'; then sed -i '1s|^#!/bin/|#!/usr/bin/|' "$f"; fi
    done
    # binaries find rpm's own libraries in this store path, never in /usr/lib64
    for f in usr/bin/* usr/lib/rpm/* usr/lib64/*.so*; do
      [ -L "$f" ] || [ ! -f "$f" ] && continue
      if head -c4 "$f" | grep -q ELF; then
        patchelf --add-rpath $out/usr/lib64 "$f"
      fi
    done
    # The macro/script layer must be FHS-clean (shebangs, tool paths)
    if grep -rl /nix/store usr/lib/rpm --exclude='*.so*' | xargs -r file | grep -v ELF; then
      echo "store paths leaked into rpm config dir" >&2; exit 1
    fi
  '';
  # no shebang patching (scripts in usr/lib/rpm must say /bin/sh, /usr/bin/...)
  dontPatchShebangs = true;
  # usr/lib/rpm/find-debuginfo.sh -> ../../bin/find-debuginfo resolves only in the FHS root
  dontCheckForBrokenSymlinks = true;
  dontStrip = false;
  dontPatchELF = true;

  passthru.configDir = "usr/lib/rpm";
}
