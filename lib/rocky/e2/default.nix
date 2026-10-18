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
in
{ inherit small glibc probe rpmConfig ccw reloc; } // small
