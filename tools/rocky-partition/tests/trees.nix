# Relocated build trees used by the rocky-partition tests (reloc-tree.nix):
#   glibc  the [NF-S3] build (stage0 toolchain through the nixpkgs wrappers,
#          glibc.site, P1 as a sed) -> checks.nn-partition-replay
#   e3.*   experiment E3 (docs/research/nix-native/experiments/E3.md): xz,
#          expat, libxcrypt, ncurses, krb5, built with nixpkgs' cc and
#          nixpkgs build dependencies (the partition rules are the subject,
#          not the toolchain)
{ pkgs, stage0 }:
let
  inherit (pkgs) lib;
  s0 = stage0;
  relocTree = import ./reloc-tree.nix { inherit pkgs stage0; };
  hoistFhs = name: tree: pkgs.runCommand name { } ''
    mkdir -p $out; for d in include lib64 lib bin; do [ -e ${tree}/usr/$d ] && { mkdir -p $out/$d; cp -rs ${tree}/usr/$d/. $out/$d/; }; done; true
  '';
  # %gpgverify runs gpg2/gpgv2 (Fedora's names for gnupg's gpg/gpgv)
  gpgv2 = pkgs.runCommand "gpgv2" { } "mkdir -p $out/bin; ln -s ${pkgs.gnupg}/bin/gpgv $out/bin/gpgv2; ln -s ${pkgs.gnupg}/bin/gpg $out/bin/gpg2";
  # systemd-rpm-macros is not part of stage0: the few macros the E3 specs use
  systemdMacros = ''
    %_unitdir %{_prefix}/lib/systemd/system
    %_userunitdir %{_prefix}/lib/systemd/user
    %_tmpfilesdir %{_prefix}/lib/tmpfiles.d
    %_presetdir %{_prefix}/lib/systemd/system-preset
    %systemd_requires %{nil}
    %systemd_post() %{nil}
    %systemd_preun() %{nil}
    %systemd_postun() %{nil}
    %systemd_postun_with_restart() %{nil}
  '';
in
{
  inherit relocTree;

  glibc = relocTree {
    srpm = "glibc";
    bigParallel = true;
    buildInputs = [ (hoistFhs "glibc-build-deps-hoisted" s0.glibcBuildDeps) ];   # gd/png/z/selinux/audit/cap + sdt.h
    configSite = [ ./glibc.site ];
    # kernel headers are a separate store path (E2 decides whether the view replaces this)
    specSed = [ "s|--with-headers=%{_prefix}/include|--with-headers=${s0.rpms.kernel-headers}/usr/include|" ];
    # like nixpkgs glibc: no self-rpath and no ld-wrapper rpaths (ld.so must not have DT_RPATH)
    env = { NIX_NO_SELF_RPATH = "1"; NIX_DONT_SET_RPATH = "1"; };
    # Nix-side glibc patch P1 as a one-line sed: ld.so must not read the host's /etc/ld.so.cache
    postPrep = ''
      sed -i "s|# define LD_SO_CACHE SYSCONFDIR \"/ld.so.cache\"|# define LD_SO_CACHE \"$NIX_RPM_PREFIX/etc/ld.so.cache\"|" sysdeps/generic/dl-cache.h
      grep -n 'define LD_SO_CACHE' sysdeps/generic/dl-cache.h
    '';
  };

  # nixpkgs cc, the design config.site (config-e3.site); brp-ldconfig off (nixpkgs ldconfig
  # cannot open its cache dir in the shim; the specs install their soname links anyway);
  # QA_RPATHS: check-rpaths calls every absolute non-/usr RUNPATH (store paths) "invalid"
  e3 = lib.mapAttrs (n: a: relocTree ({ srpm = n; cc = "nixpkgs"; baseConfigSite = ./config-e3.site;
    defines = { __brp_ldconfig = "%{nil}"; }; env = { QA_RPATHS = "0x0002"; }; } // a)) {
    xz = {
      tools = with pkgs; [ autoconf automake libtool gpgv2 ];
    };
    expat = {
      tools = with pkgs; [ autoconf automake libtool xmlto docbook_xml_dtd_42 docbook_xsl gpgv2 ];
    };
    libxcrypt = {
      cc = pkgs.gcc14;   # gcc 15: -Werror=unterminated-string-initialization
      # %install deletes every non-directory of the buildroot, the BUILDROOT/usr fold link
      # too, so find-debuginfo writes a real BUILDROOT/usr (design §1.2 fold-usr hazard)
      specSed = [ "s|^find %{buildroot} *\\\\$|find %{buildroot} -not -path %{buildroot}/usr \\\\|" ];
      # fipscheck is not in nixpkgs; the spec only uses fipshmac for the .hmac files
      tools = with pkgs; [ autoconf automake libtool gpgv2 (writeShellScriptBin "fipshmac" ''
        [ "$1" = -d ] || exit 1; d=$2; shift 2
        for f; do ${openssl}/bin/openssl dgst -sha256 -hmac orboDeJITITejsirpADONivirpUkvarP -r "$f" | cut -d' ' -f1 > "$d/''${f##*/}.hmac"; done
      '') ];
    };
    ncurses = {
      cc = pkgs.gcc14;   # ncurses 6.4 C++ binding vs gcc 15 (NCURSES_BOOL)
      tools = with pkgs; [ pkg-config gpgv2 ];
      buildInputs = [ pkgs.gpm ];
    };
    krb5 = {
      tools = with pkgs; [ autoconf automake libtool pkg-config flex bison gpgv2 git
        (python3.withPackages (p: [ p.sphinx ])) keyutils tcl e2fsprogs.scripts ];   # scripts: compile_et, mk_cmds
      buildInputs = with pkgs; [ e2fsprogs libedit ncurses keyutils libselinux linux-pam tcl libverto openldap lmdb
        openssl cmocka
        # Rocky's openssl ships <openssl/fips.h> (FIPS_mode); nixpkgs' does not
        (writeTextDir "include/openssl/fips.h" ''
          #include <openssl/evp.h>
          static inline int FIPS_mode(void) { return EVP_default_properties_is_fips_enabled(NULL); }
        '') ];
      extraMacros = systemdMacros;
      failTail = 3000;
      # %autosetup -S git + git am: auto gc during `git am` races ("invalid object")
      env = { QA_RPATHS = "0x0002"; GIT_CONFIG_COUNT = "2"; GIT_CONFIG_KEY_0 = "gc.auto"; GIT_CONFIG_VALUE_0 = "0";
              GIT_CONFIG_KEY_1 = "maintenance.auto"; GIT_CONFIG_VALUE_1 = "false"; };
      # nixpkgs' autoreconf 2.72 rejects krb5's K5_AC_INIT; autoconf + autoheader is what it needs
      # and the build environment reached through target macros (what E2's self-prefix alias is for)
      specSed = [ "s|^autoreconf -fiv$|autoconf -f \\&\\& autoheader -f|"
        "s|^source %{_libdir}/tclConfig.sh|source ${pkgs.tcl}/lib/tclConfig.sh|"
        "s|^INCLUDES=-I%{_includedir}/et|INCLUDES=-I${pkgs.e2fsprogs.dev}/include/et|"
        # `echo %{_pkgdocdir} | sed s,krb5,krb5-libs,g` also rewrites the store name of the prefix
        "s|^%define libsdocdir .*|%define libsdocdir %{_docdir}/krb5-libs|"
        # brp-compress leaves this one page uncompressed in the spike tree (not investigated)
        "s|^%{_mandir}/man8/kdb5_ldap_util.8.gz$|%{_mandir}/man8/kdb5_ldap_util.8*|" ];
    };
  };
}
