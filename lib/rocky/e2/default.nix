# E2 (docs/nix-native-design.md §9): does the declared-input /usr view plus the
# $out self-prefix alias keep relocated builds identical, and does it replace
# spec substitutions (glibc's --with-headers=%{_prefix}/include)?
# Results: docs/research/nix-native/experiments/E2.md.
#
#   nix build .#nn.toolShim.e2.<srpm>.{view,noview,compare}
#   nix build .#nn.toolShim.e2.glibc.compareNF      (+ the [NF-S3] build)
#
# Experiment code only: nothing else imports it.
{ bootPkgs, stage0, self, ... }:
let
  pkgs = bootPkgs;
  inherit (pkgs) lib;
  s0 = stage0;
  ccw = import ./ccwrap.nix { inherit pkgs stage0; };
  macroTrees = with s0.rpms; [ redhat-rpm-config rocky-release efi-srpm-macros fonts-srpm-macros forge-srpm-macros
    go-srpm-macros kernel-srpm-macros lua-srpm-macros ocaml-srpm-macros openblas-srpm-macros package-notes-srpm-macros
    perl-srpm-macros pyproject-srpm-macros python-srpm-macros qt6-srpm-macros ];
  # rpm configuration dir as Rocky has it at /usr/lib/rpm (rpm's own + macro packages), as [NF-S3]
  rpmConfig = pkgs.runCommand "rocky-rpm-config" { } ''
    mkdir -p $out
    cp -r ${s0.rpm}/usr/lib/rpm/. $out/; chmod -R u+w $out
    for t in ${lib.concatStringsSep " " (map toString macroTrees)}; do
      [ -d $t/usr/lib/rpm ] && { cp -r $t/usr/lib/rpm/. $out/; chmod -R u+w $out; }
    done
  '';
  reloc = import ./reloc.nix { inherit pkgs stage0 ccw rpmConfig; toolShim = self.toolShim; };

  hoistFhs = name: tree: pkgs.runCommand name { } ''
    mkdir -p $out; for d in include lib64 lib bin; do [ -e ${tree}/usr/$d ] && { mkdir -p $out/$d; cp -rs ${tree}/usr/$d/. $out/$d/; }; done; true
  '';
  kh = s0.rpms.kernel-headers;            # Rocky kernel-headers (FHS tree: usr/include)
  glibcDeps = hoistFhs "glibc-build-deps-hoisted" s0.glibcBuildDeps;   # gd/png/z/selinux/audit/cap + sdt.h

  # the outputs of a nixpkgs package a Rocky -devel/-libs/main RPM would cover
  # (dev first: headers, .pc; then libs and data; no debug/doc/man)
  outs = p: map (o: p.${o}) (lib.filter (o: p ? ${o}) [ "dev" "out" "lib" ]);

  # per SRPM: library inputs (cc-wrapper flags, both variants), BuildRequires
  # tools (PATH, both variants) and the declared inputs of the view variant
  # (= library inputs + BuildRequires tool packages; the generic stdenv tools
  # are PATH-only, as in the design).
  # redhat-rpm-config's gpgverify (%gpgverify in %prep) runs gpgv2 (Rocky's gnupg2 name)
  gpgv2 = pkgs.runCommand "gpgv2" { } "mkdir -p $out/bin; ln -s ${pkgs.gnupg}/bin/gpgv $out/bin/gpgv2";
  # nixpkgs' libselinux/libacl find libdl/libpthread through their RUNPATH in
  # nixpkgs' glibc 2.42, whose stubs need GLIBC_ABI_DT_X86_64_PLT from the libc
  # actually loaded (stage0's 2.39): sed/sed fails to run in the build
  # (help2man).  Copies whose RUNPATH resolves them in the stage0 libc.  Same
  # inputs for both variants.
  forStage0Libc = name: dev: libs: pkgs.runCommand "${name}-for-stage0-libc" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
    mkdir -p $out/lib
    cp -r ${dev}/include $out/
    for l in ${toString libs}; do cp -P $l/lib/*.so* $out/lib/; done
    for f in $out/lib/*.so*; do
      [ -L $f ] && continue
      chmod u+w $f; patchelf --set-rpath ${ccw.libc}/usr/lib64:$out/lib $f
    done
  '';
  libselinuxS0 = forStage0Libc "libselinux" pkgs.libselinux.dev [ pkgs.libselinux.out pkgs.pcre2.out ];
  aclS0 = forStage0Libc "acl" pkgs.acl.dev [ pkgs.acl.out pkgs.attr.out ];
  pkgsFor = with pkgs; {
    which = { buildInputs = [ readline ncurses ]; tools = [ ]; };
    xz = { buildInputs = [ ]; tools = [ autoconf automake libtool gettext gnupg gpgv2 ]; };
    gzip = { buildInputs = [ ]; tools = [ autoconf automake less ]; extraView = [ s0.texinfo71 ]; };
    sed = { buildInputs = [ aclS0 libselinuxS0 ]; tools = [ autoconf automake ]; };
    m4 = { buildInputs = [ ]; tools = [ autoconf automake gettext ]; };
    expat = { buildInputs = [ ]; tools = [ autoconf automake libtool xmlto gnupg gpgv2 ]; };
  };
  small = lib.mapAttrs (srpm: d:
    let
      viewInputs = lib.concatMap outs (d.buildInputs ++ d.tools) ++ d.extraView or [ ];
      mk = variant: reloc { inherit srpm variant viewInputs; inherit (d) buildInputs tools; configSite = [ ./config.site ]; };
      r = { view = mk "view"; noview = mk "noview"; };
    in r // { compare = compare srpm [ r.noview r.view ]; }) pkgsFor;

  # positive control (probe/e2probe.spec): a declared input that only the view
  # makes reachable (not a cc-wrapper buildInput)
  probeDep = pkgs.runCommand "e2probe-dep" { } ''
    mkdir -p $out/include/e2probe-dep $out/lib64/pkgconfig
    # code in the header, so DWARF names it (the compiled-in reference into the view)
    printf '#define E2PROBE_DEP 42\nstatic inline int e2probe_dep(int x) { return x * E2PROBE_DEP; }\n' \
      > $out/include/e2probe-dep/e2probe-dep.h
    printf 'Name: e2probe-dep\nVersion: 1\nDescription: E2\n' > $out/lib64/pkgconfig/e2probe-dep.pc
  '';
  probe =
    let
      mk = variant: reloc {
        srpm = "e2probe";
        inherit variant;
        viewInputs = [ probeDep ];
        configSite = [ ./config.site ];
        local = { dir = ./probe; version = "1"; release = "1.el10_2"; dist = ".el10_2"; };
      };
      r = { view = mk "view"; noview = mk "noview"; };
    in r // { compare = compare "e2probe" [ r.noview r.view ]; };

  # library hazard (review finding on E2): libe2lib.so in the view, linked by
  # probelib/e2probelib.spec via -L%{_libdir} (the alias) and via ld's built-in
  # SEARCH_DIR("=/usr/lib64") (the view's /usr/lib64), with the dependency as
  # cc-wrapper input or not, and with the alias showing lib/lib64 or not
  # (ROCKY_PREFIX_VIEW_DIRS).  run-outside.txt: the installed programs run
  # outside the shim; compare.py's NEEDED scan: what a static guard sees.
  probeLibDep = pkgs.runCommand "e2probelib-dep" { } ''
    mkdir -p $out/lib64
    echo 'int e2lib(void) { return 42; }' > e2lib.c
    ${ccw.cc}/bin/cc -shared -fPIC -Wl,-soname,libe2lib.so -o $out/lib64/libe2lib.so e2lib.c
  '';
  probeLib =
    let
      mk = { variant, wrap, aliasDirs ? null }: reloc {
        srpm = "e2probelib";
        inherit variant aliasDirs;
        viewInputs = [ probeLibDep ];
        buildInputs = lib.optional wrap probeLibDep;
        configSite = [ ./config.site ];
        local = { dir = ./probelib; version = "1"; release = "1.el10_2"; dist = ".el10_2"; };
        outsideRun = ''
          for b in $out/bin/e2probelib-*; do
            n=$(basename $b)
            if [ -s $b ]; then $b; echo "$n outside rc=$?"; else echo "$n not-built"; fi
          done
        '';
      };
      noLib = "include libexec share";
      r = {
        noview-wrap = mk { variant = "noview"; wrap = true; };
        view-wrap = mk { variant = "view"; wrap = true; };
        view-nowrap = mk { variant = "view"; wrap = false; };
        view-wrap-nolibalias = mk { variant = "view"; wrap = true; aliasDirs = noLib; };
        view-nowrap-nolibalias = mk { variant = "view"; wrap = false; aliasDirs = noLib; };
      };
    in r // {
      compare = compare "e2probelib" (with r; [ noview-wrap view-wrap view-nowrap view-wrap-nolibalias view-nowrap-nolibalias ]);
    };

  # a real SRPM that reaches build deps through target macros (review finding
  # on E2: in the six small SRPMs every view input was also a cc-wrapper input):
  # krb5's %build does `source %{_libdir}/tclConfig.sh` and
  # `INCLUDES=-I%{_includedir}/et` (e2fsprogs' com_err headers).  noview needs
  # the tclConfig.sh substitution (the et headers also come from com_err.pc);
  # view builds the unmodified spec.  view-etviewonly: e2fsprogs (libcom_err,
  # libss) only in the view, not a cc-wrapper input -- FAILS to build (E2.md:
  # without com_err.pc on PKG_CONFIG_PATH libprofile is underlinked), kept as
  # the record of that run.
  # Rocky's tcl-devel has tclConfig.sh in %{_libdir} (= lib64); nixpkgs' in lib
  tclRocky = pkgs.runCommand "tcl-rocky-layout" { } ''
    mkdir -p $out; cp -rs ${pkgs.tcl}/. $out/; ln -s lib $out/lib64
  '';
  krb5 =
    let
      # configure runs a program linked with libss: copies resolved in the stage0
      # libc (as for sed, E2.md finding 7), with their .pc files (without them
      # configure's -lcom_err fallback leaves libprofile underlinked)
      e2fs = pkgs.runCommand "e2fsprogs-for-stage0-libc-pc" { } ''
        cp -r ${forStage0Libc "e2fsprogs" pkgs.e2fsprogs.dev [ pkgs.e2fsprogs.out ]} $out; chmod -R u+w $out
        mkdir -p $out/lib/pkgconfig
        for f in ${pkgs.e2fsprogs.dev}/lib/pkgconfig/*.pc; do
          sed -e "s|${pkgs.e2fsprogs.out}|$out|g" -e "s|${pkgs.e2fsprogs.dev}|$out|g" $f > $out/lib/pkgconfig/''${f##*/}
        done
      '';
      # compile_et / mk_cmds (Rocky: libcom_err-devel, libss-devel); nixpkgs'
      # e2fsprogs does not install them: made from Rocky's e2fsprogs source
      etTools = pkgs.runCommand "e2fsprogs-et-ss-tools" { } ''
        tar xf ${s0.lib.unpackSrpm "e2fsprogs"}/e2fsprogs-*.tar.xz --wildcards '*/lib/et/*' '*/lib/ss/*'
        cd e2fsprogs-*/lib
        mkdir -p $out/bin $out/share/et $out/share/ss
        cp et/et_c.awk et/et_h.awk $out/share/et/; cp ss/ct_c.awk ss/ct_c.sed $out/share/ss/
        for t in compile_et:et mk_cmds:ss; do
          n=''${t%:*} d=''${t#*:}
          sed -e 's|@AWK@|${pkgs.gawk}/bin/awk|g' -e "s|@datadir@|$out/share|g" -e 's|@SED@|${pkgs.gnused}/bin/sed|g' \
            $d/$n.sh.in > $out/bin/$n
          ! grep -n '@[A-Za-z_]*@' $out/bin/$n
        done
        chmod +x $out/bin/*
      '';
      # Rocky's openssl-devel has <openssl/fips.h> (FIPS_mode(), a RHEL patch),
      # which krb5's RHEL patches include; nixpkgs' has not: a stand-in header
      fipsH = pkgs.runCommand "openssl-rhel-fips-h" { } ''
        mkdir -p $out/include/openssl
        printf '%s\n' '#include <openssl/evp.h>' '#define FIPS_mode() EVP_default_properties_is_fips_enabled(NULL)' \
          > $out/include/openssl/fips.h
      '';
      # %prep runs getconf (Rocky: glibc-common; stage0's needs /lib64/ld-linux*)
      getconf = pkgs.runCommand "getconf" { } "mkdir -p $out/bin; ln -s ${lib.getBin pkgs.glibc}/bin/getconf $out/bin/getconf";
      sphinx = pkgs.python3.withPackages (p: [ p.sphinx ]);
      libs = with pkgs; [ fipsH openssl keyutils libselinuxS0 pam libverto openldap lmdb libedit ncurses tclRocky ];
      # nixpkgs has autoconf 2.69 (too old: the spec passes --runstatedir) and 2.73,
      # whose autoreconf misses krb5's K5_AC_INIT ("AC_INIT not found"); Rocky 10 has
      # 2.71.  %prep's `autoreconf -fiv` gets a stand-in that runs what autoreconf
      # would (krb5 uses neither aclocal, libtool nor automake), in both variants
      autoreconf = pkgs.writeShellScriptBin "autoreconf" ''
        echo "e2 autoreconf stand-in: autoconf --force && autoheader --force" >&2
        autoconf --force && autoheader --force
      '';
      tools = with pkgs; [ autoreconf autoconf automake bison flex pkg-config git etTools sphinx gnupg gpgv2 getconf ];
      mk = variant: { etWrapped ? true }: reloc {
        srpm = "krb5";
        inherit variant tools;
        buildInputs = libs ++ lib.optional etWrapped e2fs;
        viewInputs = lib.concatMap outs (libs ++ [ e2fs ] ++ tools);
        configSite = [ ./config.site ];
        specSubstitutions = [
          { from = "source %{_libdir}/tclConfig.sh"; to = "source ${tclRocky}/lib64/tclConfig.sh"; }
        ];
        # relocation hazard unrelated to the view (both variants): libsdocdir is
        # %{_pkgdocdir} with EVERY "krb5" replaced, and $out's name contains krb5
        # (/nix/store/<h>-krb5-libs-1.21.3.../share/doc/krb5-libs: %install's rm fails)
        commonSubstitutions = [ { from = "sed -e s,krb5,krb5-libs,g"; to = "sed -e s,krb5$,krb5-libs,"; } ];
        # systemd-rpm-macros (BuildRequires: systemd-units) is not among the macro trees
        defines = [ "_unitdir %{_prefix}/lib/systemd/system" "_tmpfilesdir %{_prefix}/lib/tmpfiles.d"
          "systemd_post() %{nil}" "systemd_preun() %{nil}" "systemd_postun_with_restart() %{nil}" ];
        bigParallel = true;
      };
      r = { noview = mk "noview" { }; view = mk "view" { }; view-etviewonly = mk "view" { etWrapped = false; }; };
    in r // {
      compare = compare "krb5" [ r.noview r.view ];
    };

  glibc =
    let
      mk = variant: reloc {
        srpm = "glibc";
        inherit variant;
        # declared inputs: kernel-headers, the hoisted build deps, BuildRequires tools
        viewInputs = [ kh glibcDeps s0.texinfo71 ] ++ lib.concatMap outs (with pkgs; [ bison gettext perl python3 gawk procps util-linux gdb ]);
        buildInputs = [ glibcDeps ];
        configSite = [ ./config.site ./glibc.site ];
        # [NF-S3]: kernel headers are a separate store path -> per-package substitution;
        # E2 drops it in the view variant (%{_prefix}/include resolves through the alias)
        specSubstitutions = [ { from = "--with-headers=%{_prefix}/include"; to = "--with-headers=${kh}/usr/include"; } ];
        env = { NIX_NO_SELF_RPATH = "1"; NIX_DONT_SET_RPATH = "1"; };
        # Nix-side glibc patch P1 as in [NF-S3] (one-line sed)
        postPrep = ''
          sed -i "s|# define LD_SO_CACHE SYSCONFDIR \"/ld.so.cache\"|# define LD_SO_CACHE \"$NIX_RPM_PREFIX/etc/ld.so.cache\"|" sysdeps/generic/dl-cache.h
          grep -n 'define LD_SO_CACHE' sysdeps/generic/dl-cache.h
        '';
        bigParallel = true;
      };
      r = { view = mk "view"; noview = mk "noview"; };
    in r // {
      compare = compare "glibc" [ r.noview r.view ];
      # determinism control (our noview vs the [NF-S3] spike build: same recipe through
      # the spike's inline shim) is run by hand, a store path literal being impure; E2.md
    };

  compare = name: trees: pkgs.runCommand "e2-compare-${name}" {
    nativeBuildInputs = [ pkgs.python3 pkgs.zstd ];
    # the view's bin/ (PATH of the builds), to tell view refs from dangling ones
    E2_VIEW_PATH = (lib.last trees).viewPath;
  } ''
    python3 -I ${./compare.py} $out ${lib.concatMapStringsSep " " toString trees}
  '';
  # finding 4 (E2.md): a macros.d file loses against platform/x86_64-linux/macros;
  # redhat/macros (read later) wins; with and without --target
  macroPrecedence = pkgs.runCommand "e2-macro-precedence" { } ''
    export PATH=${s0.rpm}/usr/bin:${pkgs.coreutils}/bin
    cp -r ${rpmConfig} cfg; chmod -R u+w cfg
    printf '%%_prefix /e2/macros.d\n%%_sysconfdir /e2/etc\n%%e2_marker set\n' > cfg/macros.d/macros.zz-e2
    printf '%%_libdir /e2/redhat/lib64\n' >> cfg/redhat/macros
    export RPM_CONFIG_DIR=$PWD/cfg
    for t in "" "--target x86_64"; do
      for r in rpm rpmbuild; do
        echo "$r $t: $(${self.toolShim} -- $r $t --eval '_prefix=%{_prefix} _sysconfdir=%{_sysconfdir} _libdir=%{_libdir} e2_marker=%{e2_marker}')" >> $out
      done
    done
    cat $out
  '';
in
{ inherit small glibc probe probeLib krb5 rpmConfig ccw reloc macroPrecedence; } // small
