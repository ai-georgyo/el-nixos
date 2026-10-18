# stage0 system C library: Rocky's glibc-2.39 tarball (no Rocky patches),
# configured like glibc.spec (prefix /usr, usrmerge, bind-now, SSP strong,
# CET, x86-64 baseline for ld.so, same configure switches), compiled by
# bootstrap/gcc.nix pass 1, for x86_64 and i686 (glibc.spec builds both on
# x86_64), installed as an FHS tree in $out/usr.
#
# Why not copy nixpkgs' glibc: its ld.so has the store hard-coded as system
# library directory and reads <store>/etc/ld.so.cache, so it can never act as
# /lib64/ld-linux-x86-64.so.2 for FHS binaries; and it is 2.42, whose newer
# symbol versions would leak into everything stage0 compiles.  A stage0 libc
# at Rocky's own version (2.39) keeps stage0 output ABI-compatible with Rocky.
{ pkgs, srpm, gccPass1, binutils, kernelHeaders }:
let
  e = srpm.lockEntry;
  bu = "${binutils}/usr/bin";
  cc = "${gccPass1}/bin/x86_64-redhat-linux-gcc";
  tools = "AR=${bu}/ar AS=${bu}/as LD=${bu}/ld NM=${bu}/nm OBJCOPY=${bu}/objcopy OBJDUMP=${bu}/objdump RANLIB=${bu}/ranlib READELF=${bu}/readelf STRIP=${bu}/strip GPROF=${bu}/gprof"
    # interpreters of installed scripts (ldd, sotruss, xtrace, tzselect, mtrace):
    # FHS paths, not the configure-time store paths (Rocky: /usr/bin/bash after
    # brp-mangle-shebangs)
    + " BASH_SHELL=/usr/bin/bash KSH=/usr/bin/bash PERL=/usr/bin/perl";
  common = "--prefix=/usr --with-headers=${kernelHeaders}/usr/include --enable-kernel=3.2"
    + " --enable-bind-now --enable-stack-protector=strong --disable-werror --disable-profile"
    + " --without-selinux --disable-crypt --disable-build-nscd --disable-nscd --disable-systemtap"
    + " --without-gd";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "stage0-glibc";
  version = "${e.version}-${e.release}";
  src = "${srpm}/glibc-${e.version}.tar.xz";

  nativeBuildInputs = with pkgs; [ gnumake bison python3 perl gawk gnused texinfo gettext ];

  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    export CONFIG_SITE=NONE
    # like glibc.spec: usrmove symlinks in the install root, so /lib64 -> /usr/lib64
    for d in bin lib lib64 sbin; do mkdir -p $out/usr/$d; ln -s usr/$d $out/$d; done

    # --- i686 (installed first, then pruned to libraries, as glibc.spec does)
    mkdir build-32 && pushd build-32
    ../configure ${common} --host=i686-redhat-linux-gnu --build=x86_64-pc-linux-gnu \
      CC="${cc} -m32" CXX=false CFLAGS="-O2 -g -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection" \
      ${tools}
    env LDFLAGS.so="-Wl,--hash-style=both" LDFLAGS-rtld="-Wl,--hash-style=both" make -r -j$NIX_BUILD_CORES
    make -r -j$NIX_BUILD_CORES install_root=$out install
    popd
    pushd $out
    rm -rf etc var usr/bin usr/lib/gconv usr/libexec usr/sbin usr/share
    rm -f usr/lib/libnss_db* usr/lib/libnss_hesiod* usr/lib/libnsl* usr/lib/libc_malloc_debug.so
    popd

    # --- x86_64
    mkdir build-64 && pushd build-64
    ../configure ${common} --host=x86_64-redhat-linux-gnu --build=x86_64-pc-linux-gnu \
      CC="${cc}" CXX=false CFLAGS="-O2 -g -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection" \
      --enable-cet --with-rtld-early-cflags=-march=x86-64 \
      ${tools}
    env LDFLAGS.so="-Wl,--hash-style=both" LDFLAGS-rtld="-Wl,--hash-style=both" make -r -j$NIX_BUILD_CORES
    make -r -j$NIX_BUILD_CORES install_root=$out install
    popd
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd $out
    # the usrmove links belong to the buildroot skeleton, not to this tree
    rm bin lib lib64 sbin
    mkdir -p etc
    printf 'include ld.so.conf.d/*.conf\n' > etc/ld.so.conf
    mkdir -p etc/ld.so.conf.d
    rm -rf usr/share/info/dir var/db/Makefile
    # sanity: the dynamic loader lands where PT_INTERP says
    test -e usr/lib64/ld-linux-x86-64.so.2
    test -e usr/lib/ld-linux.so.2
    # Debug info records the build-time include dirs (kernel headers, pass-1
    # gcc: store paths). crt*.o / libc_nonshared.a / libc.a are linked into
    # every program, so strip debug info everywhere (Rocky ships it in
    # glibc-debuginfo anyway).
    find usr -type f \( -name '*.so*' -o -name '*.a' -o -name '*.o' \) | while read -r f; do
      if head -c4 "$f" | grep -q ELF || head -c7 "$f" | grep -q '!<arch>'; then
        ${bu}/strip --strip-debug "$f"
      fi
    done
    for f in usr/bin/* usr/sbin/* usr/libexec/getconf/* usr/lib64/gconv/*.so usr/lib/gconv/*.so usr/lib64/audit/*.so; do
      [ -f "$f" ] && head -c4 "$f" | grep -q ELF && ${bu}/strip --strip-debug "$f" || true
    done
    if grep -rl /nix/store .; then
      echo "stage0 glibc refers to the store (files above)" >&2; exit 1
    fi
    runHook postInstall
  '';
  dontFixup = true;
  hardeningDisable = [ "all" ];
  passthru.fhsRoot = "usr";
}
