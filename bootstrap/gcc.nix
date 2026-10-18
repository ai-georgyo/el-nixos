# stage0 GCC from Rocky's gcc SRPM tarball (gcc-14.3.1-20251022 = the Red Hat
# gcc-14 branch snapshot) + the Rocky patches that matter for codegen,
# configured like gcc.spec does on x86_64, built by the nixpkgs toolchain.
#
# Two flavours (the classic build-many-glibcs.py dance, needed because Rocky's
# glibc.spec builds a 32-bit glibc with `gcc -m32`, so the compiler must be
# multilib, and multilib target libraries need a 32+64-bit libc first):
#
#  pass = 1  "x86_64-redhat-linux-gcc": a cross-style C compiler living in the
#            store, no libc (--without-headers), static libgcc for -m64/-m32.
#            Only used to compile bootstrap/glibc.nix.
#  pass = 2  the real stage0 compiler, installed as an FHS tree ($out/usr/...):
#            native x86_64-redhat-linux, multilib, C/C++/LTO, target
#            libraries (libgcc_s, libstdc++, libgomp, ...) compiled against the
#            stage0 glibc through --with-build-sysroot, so `gcc` inside the
#            chroot behaves exactly like a distro compiler: headers from
#            /usr/include, crt files and libc from /usr/lib64, PT_INTERP
#            /lib64/ld-linux-x86-64.so.2, no RUNPATH.
#
# The compiler *executables* (gcc, cc1, collect2, lto1, ...) are host programs
# linked against nixpkgs glibc/gmp/mpfr/mpc (RUNPATH into the store) — they
# run in the stage0 chroot because /nix/store is visible there, and they never
# leak into what they compile.
{ pkgs, srpm, binutils, pass ? 2, sysroot ? null, languages ? [ "c" "c++" "lto" ] }:
assert pass == 2 -> sysroot != null;
let
  inherit (pkgs) lib;
  e = srpm.lockEntry;
  date = "20251022";
  gccRelease = builtins.head (lib.splitString "." e.release); # "4" of "4.4.el10"
  triple = "x86_64-redhat-linux";
  major = lib.versions.major e.version;

  # Shared with Rocky's CONFIGURE_OPTS_BASE / _NATIVE (x86_64, rhel >= 10)
  rockyOpts = [
    "--with-bugurl=https://bugs.rockylinux.org"
    "--enable-checking=release" "--with-system-zlib" "--enable-__cxa_atexit"
    "--disable-libunwind-exceptions" "--enable-gnu-unique-object" "--enable-linker-build-id"
    "--with-gcc-major-version-only" "--enable-initfini-array"
    "--enable-multilib" "--with-linker-hash-style=gnu" "--enable-gnu-indirect-function"
    "--enable-cet" "--with-tune=generic" "--with-arch_64=x86-64-v3" "--with-arch_32=x86-64"
  ];

  pass1Opts = [
    "--target=${triple}"
    "--with-as=${binutils}/usr/bin/as" "--with-ld=${binutils}/usr/bin/ld"
    "--with-build-time-tools=${binutils}/usr/bin"
    "--enable-languages=c" "--disable-bootstrap"
    "--disable-shared" "--disable-threads" "--without-headers" "--with-newlib"
    "--with-glibc-version=2.39"
    "--disable-libatomic" "--disable-decimal-float" "--disable-libffi" "--disable-libgomp"
    "--disable-libitm" "--disable-libmpx" "--disable-libquadmath" "--disable-libsanitizer"
    "--disable-libssp" "--disable-libvtv" "--disable-libcc1" "--disable-plugin"
    "--disable-nls" "--without-isl"
  ];

  pass2Opts = [
    "--prefix=/usr" "--mandir=/usr/share/man" "--infodir=/usr/share/info"
    "--build=${triple}" "--host=${triple}" "--target=${triple}"
    "--enable-shared" "--enable-threads=posix" "--enable-plugin"
    "--enable-libstdcxx-backtrace" "--with-libstdcxx-zoneinfo=/usr/share/zoneinfo"
    "--enable-host-pie" "--enable-host-bind-now"
    "--enable-languages=${lib.concatStringsSep "," languages}"
    # FHS-native, no sysroot (like Rocky): configure/make/install run in a
    # namespace where the stage0 libc tree *is* /usr (see fhsRun below)
    "--with-native-system-header-dir=/usr/include"
    "--with-build-time-tools=${binutils}/usr/bin"
    # stage0 deviations (docs/stage0.md): no 3-stage/profiled bootstrap, no
    # sanitizers/offloading/fortran/go/d/ada; isl built in-tree from the SRPM.
    "--disable-bootstrap" "--disable-libsanitizer" "--disable-nls"
    # libcc1 (gdb's compile plugin, Rocky's gcc-gdb-plugin) is a host-side
    # library linked against nixpkgs libs; it must not sit in /usr/lib64
    "--disable-libcc1"
  ];
in
pkgs.gcc14Stdenv.mkDerivation {
  pname = if pass == 1 then "stage0-gcc-pass1" else "stage0-gcc";
  version = "${e.version}-${e.release}";

  src = "${srpm}/gcc-${e.version}-${date}.tar.xz";

  # %prep of gcc.spec (subset, same -p levels)
  prePatch = ''
    patch -p0 < ${srpm}/gcc14-hack.patch
    patch -p0 < ${srpm}/gcc14-libgomp-omp_h-multilib.patch
    patch -p0 < ${srpm}/gcc14-libtool-no-rpath.patch
    patch -p0 < ${srpm}/gcc14-no-add-needed.patch
    patch -p0 < ${srpm}/gcc14-Wno-format-security.patch
    patch -p0 < ${srpm}/gcc14-rh1574936.patch
    patch -p1 < ${srpm}/gcc14-pr101523.patch
    echo 'Red Hat ${e.version}-${gccRelease}' > gcc/DEV-PHASE
    cp -a libstdc++-v3/config/cpu/i{4,3}86/atomicity.h
    ./contrib/gcc_update --touch
    sed -i -e 's/Common Driver Var(flag_report_bug)/& Init(1)/' gcc/common.opt
    sed -i -e 's/m_report_bug = false;/m_report_bug = true;/' gcc/diagnostic.cc
    # libgcc: -fasynchronous-unwind-tables is in Rocky's OPT_FLAGS
    sed -i -e 's/-fno-exceptions /-fno-exceptions -fno-asynchronous-unwind-tables /' libgcc/Makefile.in
  '' + lib.optionalString (pass == 2) ''
    # isl in-tree (gcc.spec builds the same isl-0.24 separately and links it)
    tar -xjf ${srpm}/isl-0.24.tar.bz2
    mv isl-0.24 isl
  '';

  nativeBuildInputs = with pkgs; [ perl flex bison texinfo m4 python3 ]
    ++ lib.optional (pass == 2) pkgs.bubblewrap;
  buildInputs = with pkgs; [ gmp mpfr libmpc zlib ];

  configurePlatforms = [ ];
  dontAddPrefix = pass == 2;
  dontDisableStatic = true;
  configureFlags = rockyOpts ++ (if pass == 1 then pass1Opts else pass2Opts);

  preConfigure = ''
    export CONFIG_SITE=NONE
    mkdir ../obj && cd ../obj
    configureScript=../$sourceRoot/configure
  '' + lib.optionalString (pass == 2) ''
    # A native gcc build compiles *and runs* target test programs (libstdc++,
    # libgomp, ... configure), which have PT_INTERP /lib64/ld-linux-x86-64.so.2
    # and link /usr/lib64/libc.so.  Run configure/make/install in a user+mount
    # namespace whose /usr is the stage0 sysroot (/lib64, /lib -> usr/...),
    # i.e. on a genuine FHS system.  The nixpkgs host compiler and tools are
    # unaffected (they only use store paths).
    fhsRun() {
      bwrap --unshare-user --uid "$(id -u)" --gid "$(id -g)" \
        --tmpfs / --bind /nix /nix --bind "$NIX_BUILD_TOP" "$NIX_BUILD_TOP" \
        --dev /dev --proc /proc --tmpfs /tmp --ro-bind /etc /etc --ro-bind /bin /bin \
        --ro-bind ${sysroot}/usr /usr --symlink usr/lib64 /lib64 --symlink usr/lib /lib \
        --chdir "$PWD" "$@"
    }
    make() { fhsRun make "$@"; }
    configureScript="fhsRun ../$sourceRoot/configure"
    fhsRun /lib64/ld-linux-x86-64.so.2 --version | head -1
  '';

  # Host programs: plain -O2 (no -g: keeps the stage0 build small/fast).
  # Target libraries: Rocky's optflags core (the arch/tune defaults are built in).
  env = {
    CFLAGS = "-O2";
    CXXFLAGS = "-O2";
  };
  preBuild = ''
    makeFlagsArray+=(
      "CFLAGS_FOR_TARGET=-O2 -g -fexceptions -fstack-protector-strong -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection"
      "CXXFLAGS_FOR_TARGET=-O2 -g -fstack-protector-strong -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection"
      "LDFLAGS_FOR_TARGET=-Wl,-z,relro,-z,now"
    )
  '';
  buildFlags = lib.optionals (pass == 1) [ "all-gcc" "all-target-libgcc" ];
  installTargets = if pass == 1 then [ "install-gcc" "install-target-libgcc" ] else [ "install" ];
  installFlags = lib.optionals (pass == 2) [ "DESTDIR=$(out)" ];
  enableParallelBuilding = true;
  enableParallelInstalling = false; # build-many-glibcs: parallel gcc install is racy
  hardeningDisable = [ "all" ];

  postInstall = lib.optionalString (pass == 2) ''
    cd $out
    FULLPATH=usr/lib/gcc/${triple}/${major}
    ln -sf gcc usr/bin/cc
    ln -sf ../bin/cpp usr/lib/cpp
    # Same layout tweaks as gcc.spec %install:
    # libgcc_s.so is a linker script in Rocky (uses the shared lib + libgcc.a)
    rm -f usr/lib64/libgcc_s.so usr/lib/libgcc_s.so
    printf '/* GNU ld script\n   Use the shared library, but some functions are only in\n   the static library.  */\nGROUP ( /lib64/libgcc_s.so.1 libgcc.a )\n' > $FULLPATH/libgcc_s.so
    mkdir -p $FULLPATH/32
    printf '/* GNU ld script\n   Use the shared library, but some functions are only in\n   the static library.  */\nGROUP ( /lib/libgcc_s.so.1 libgcc.a )\n' > $FULLPATH/32/libgcc_s.so
    # lto plugin where ar/nm/ranlib find it
    mkdir -p usr/lib/bfd-plugins
    ln -sf ../../libexec/gcc/${triple}/${major}/liblto_plugin.so usr/lib/bfd-plugins/liblto_plugin.so
    # drop headers that fixincludes copied+edited from the stage0 glibc
    # (gcc.spec does the same), and the fixincludes machinery itself
    for h in $(find $FULLPATH/include $FULLPATH/include-fixed -name '*.h' 2>/dev/null); do
      if grep -q 'It has been auto-edited by fixincludes from' $h; then rm -f $h; fi
    done
    rm -rf $FULLPATH/install-tools libexec/gcc/${triple}/${major}/install-tools
    rm -f usr/lib64/*.la usr/lib/*.la usr/lib64/libiberty.a usr/share/info/dir
    # Target objects (libgcc*.a, crt*.o, libstdc++.{a,so}, ...) end up in
    # every program; their debug info names the build sysroot (a store path),
    # so strip it (Rocky ships it in gcc-debuginfo).  Then: no target object
    # may mention the store at all (host programs in libexec/ and bin/ may).
    targets=$(find usr/lib64 usr/lib/gcc/${triple}/${major} usr/lib -maxdepth 3 -type f \
      \( -name '*.a' -o -name '*.o' -o -name '*.so*' \) -not -path '*/plugin/*' \
      -not -name 'liblto_plugin.so*' 2>/dev/null | sort -u)
    for f in $targets; do
      if head -c4 "$f" | grep -q ELF || head -c7 "$f" | grep -q '!<arch>'; then
        ${binutils}/usr/bin/strip --strip-debug "$f"
      fi
    done
    bad=$(grep -l /nix/store $targets || true)
    if [ -n "$bad" ]; then echo "target objects refer to the store: $bad" >&2; exit 1; fi
    for f in usr/lib64/*.so.* usr/lib/*.so.*; do
      [ -L "$f" ] && continue
      if ${binutils}/usr/bin/readelf -d "$f" 2>/dev/null | grep -qE 'RPATH|RUNPATH'; then
        echo "target library $f has an RPATH/RUNPATH" >&2; exit 1
      fi
    done
  '';
  dontFixup = true;

  passthru = { inherit triple major; fhsRoot = if pass == 2 then "usr" else null; };
}
