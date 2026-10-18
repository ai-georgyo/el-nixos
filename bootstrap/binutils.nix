# stage0 binutils: Rocky's binutils-2.41 tarball + all of Rocky's patches,
# configured like binutils.spec does for a native RHEL build, built by the
# nixpkgs toolchain and installed as an FHS tree ($out/usr/...).
#
# The *host* side (the ld/as/... executables) links against nixpkgs glibc and
# runs through the nixpkgs dynamic loader; that is fine because stage0 chroots
# see /nix/store read-only.  libbfd/libopcodes/libctf/libsframe are linked
# statically (--disable-shared) so nothing has to be found in /usr/lib64 by the
# nixpkgs loader.  Everything that affects *output* (default search dirs
# =/usr/lib64 etc. via --with-sysroot=/, hash style, execstack/rwx-segment
# handling, package-metadata) matches Rocky.
{ pkgs, srpm }:
let
  patches = [
    "binutils-libtool-lib64.patch" "binutils-version.patch" "binutils-export-demangle.h.patch"
    "binutils-no-config-h-check.patch" "binutils-revert-PLT-elision.patch" "binutils-2.27-aarch64-ifunc.patch"
    "binutils-do-not-link-with-static-libstdc++.patch" "binutils-special-sections-in-groups.patch"
    "binutils-gold-mismatched-section-flags.patch" "binutils-gold-warn-unsupported.patch"
    "binutils-gold-i386-gnu-property-notes.patch" "binutils-autoconf-version.patch" "binutils-libtool-no-rpath.patch"
    # Patch14 (binutils-update-linker-manual.patch) is %if enable_new_dtags: off on RHEL
    "binutils-gold-empty-dwp.patch" "binutils-testsuite-fixes.patch"
    "binutils-riscv-testsuite-fixes.patch" "binutils-gold-powerpc.patch" "binutils-handle-corrupt-version-info.patch"
    "binutils-execstack-error.patch" "binutils-BPF-reloc-4.patch" "binutils-x86-64-v3.patch" "binutils-big-merge.patch"
    "binutils-aarch64-big-bti-programs.patch" "binutils-gold-pack-relative-relocs.patch"
    "i686-AVX10.1-part-1.patch" "i686-AVX10.1-part-2.patch" "i686-AVX10.1-part-3.patch" "i686-AVX10.1-part-4.patch"
    "i686-AVX10.1-part-5.patch" "i686-AVX10.1-part-6.patch" "binutils-riscv-SUB_ULEB128.patch"
    "binutils-gold-ignore-execstack-error.patch" "binutils-ppc-dt_relr-relocs.patch" "binutils-demangler-updates.patch"
    "binutils-Intel-APX-part-1.patch" "binutils-power-11.patch" "binutils-Intel-APX-part-1-fixes.patch"
    "binutils-multilib.am.patch" "binutils-section-ordering.patch" "binutils-aarch64-RELR.patch"
    "binutils-Intel-APX-part-1-supplimental.patch"
    "binutils-s390-arch15-part-01.patch" "binutils-s390-arch15-part-02.patch" "binutils-s390-arch15-part-03.patch"
    "binutils-s390-arch15-part-04.patch" "binutils-s390-arch15-part-05.patch" "binutils-s390-arch15-part-06.patch"
    "binutils-s390-arch15-part-07.patch" "binutils-s390-arch15-part-08.patch" "binutils-s390-arch15-part-09.patch"
    "binutils-s390-arch15-part-10.patch" "binutils-s390-arch15-part-11.patch" "binutils-s390-arch15-part-12.patch"
    "binutils-s390-arch15-part-13.patch" "binutils-s390-arch15-part-14.patch" "binutils-s390-arch15-part-15.patch"
    "binutils-Intel-APX-part-1-extra-relocs.patch" "binutils-aarch64-small-plt0.patch" "binutils-s390-z17-cpu-name.patch"
    "binutils-riscv-efi.patch" "binutils-CVE-2025-5244.patch" "binutils-CVE-2025-11082.patch"
    "binutils-CVE-2025-11083.patch" "binutils-error-on-corrupted-group.patch" "binutils-suppress-ld-align-tests.patch"
  ];
  e = srpm.lockEntry;
in
pkgs.gcc14Stdenv.mkDerivation {
  pname = "stage0-binutils";
  version = "${e.version}-${e.release}";
  src = "${srpm}/binutils-${e.version}.tar.xz";
  patches = map (p: "${srpm}/${p}") patches;

  # Same %prep tweaks as binutils.spec (x86_64-relevant ones).
  postPatch = ''
    # binutils-version.patch leaves a literal %{release} for the spec to fill in
    sed -i -e 's/%{release}/${e.release}/g' bfd/Makefile{.am,.in}
    sed -i -e '/^libopcodes_la_\(DEPENDENCIES\|LIBADD\)/s,$, ../bfd/libbfd.la,' opcodes/Makefile.{am,in}
    find . -name '*.info' -exec touch {} +
  '';

  nativeBuildInputs = with pkgs; [ bison flex perl texinfo m4 ];
  buildInputs = with pkgs; [ zlib ];

  configurePlatforms = [ ];
  dontAddPrefix = true;
  dontDisableStatic = true;
  configureFlags = [
    "--build=x86_64-redhat-linux-gnu" "--host=x86_64-redhat-linux-gnu" "--target=x86_64-redhat-linux-gnu"
    "--prefix=/usr" "--libdir=/usr/lib64" "--sysconfdir=/etc" "--mandir=/usr/share/man" "--infodir=/usr/share/info"
    "--with-sysroot=/"
    "--enable-ld" "--enable-plugins" "--enable-64-bit-bfd" "--enable-default-hash-style=gnu"
    "--with-bugurl=https://bugs.rockylinux.org/"
    "--enable-gprofng=no" "--with-system-zlib"
    "--enable-compressed-debug-sections=none" "--enable-generate-build-notes=no" "--enable-relro=yes"
    "--enable-deterministic-archives=no"
    "--enable-warn-execstack=yes" "--enable-default-execstack=no" "--enable-warn-rwx-segments=yes"
    "--enable-lto" "--enable-threads=yes"
    "--enable-targets=x86_64-pep,bpf-unknown-none"
    # stage0 deviations (documented in docs/stage0.md):
    "--disable-gold"          # Rocky builds gold (not default linker); not needed to bootstrap
    "--disable-shared"        # keep host libs static so the nixpkgs loader needs no /usr/lib64
    "--disable-werror" "--without-debuginfod" "--enable-jansson=no"
  ];
  preConfigure = ''
    mkdir build && cd build
    configureScript=../configure
  '';
  enableParallelBuilding = true;
  makeFlags = [ "tooldir=/usr" "MAKEINFO=true" ];
  installFlags = [ "tooldir=/usr" "MAKEINFO=true" "DESTDIR=$(out)" ];
  hardeningDisable = [ "all" ];

  postInstall = ''
    cd $out
    # Rocky ships ld as alternatives symlink to ld.bfd; make it a plain link.
    ln -sf ld.bfd usr/bin/ld
    rm -rf usr/share/info/dir usr/lib64/*.la
    # plugins dir used by ar/nm/ranlib to find the gcc LTO plugin
    mkdir -p usr/lib/bfd-plugins
  '';
  # Keep the FHS tree untouched: no shebang patching, no RPATH shrinking,
  # no moving of man pages, no stripping of our objects.
  dontFixup = true;

  passthru.fhsRoot = "usr";
}
