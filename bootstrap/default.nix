# stage0: an FHS buildroot synthesized from nixpkgs + Rocky toolchain sources,
# then completed with Rocky's own release/macro packages built from SRPMs.
# See docs/stage0.md.
{ pkgs                    # nixpkgs (bootstrap only)
, lock                    # parsed lock/rocky-<rel>/srpms.json
, kernelHeaders ? null    # FHS tree with usr/include/{linux,asm,...}; default: nixpkgs linuxHeaders
, officialRpms ? null     # lib/sources.nix officialRpms (verification checks only)
}:
let
  inherit (pkgs) lib;
  fetch = import ../lib/fetch-srpm-seed.nix { inherit pkgs lock; };
  srpm = fetch.unpackSrpm;

  kh = if kernelHeaders != null then kernelHeaders else import ./kernel-headers.nix { inherit pkgs; };

  # ---------------------------------------------------------------- toolchain
  binutils = import ./binutils.nix { inherit pkgs; srpm = srpm "binutils"; };
  gccPass1 = import ./gcc.nix { inherit pkgs binutils; srpm = srpm "gcc"; pass = 1; };
  glibc = import ./glibc.nix { inherit pkgs binutils gccPass1; srpm = srpm "glibc"; kernelHeaders = kh; };
  # libc + kernel headers laid out as a root; mounted as /usr while building gcc (fhsRun)
  sysroot = pkgs.runCommand "stage0-sysroot" { } ''
    mkdir -p $out/usr
    cp -a ${glibc}/usr/. $out/usr/
    chmod -R u+w $out/usr
    cp -a ${kh}/usr/include/. $out/usr/include/
    for d in bin lib lib64 sbin; do ln -s usr/$d $out/$d; done
  '';
  gcc = import ./gcc.nix { inherit pkgs binutils sysroot; srpm = srpm "gcc"; pass = 2; };
  rpm = import ./rpm.nix { inherit pkgs; srpm = srpm "rpm"; };
  debugedit = import ./debugedit.nix { inherit pkgs; srpm = srpm "debugedit"; };

  # buildsys-build basics, from nixpkgs (symlinked into /usr/bin)
  tools = with pkgs; [
    bash coreutils gnused gnugrep gawk findutils diffutils gnupatch gnutar gzip bzip2 xz zstd
    cpio unzip zip pkgs.which file util-linux procps gnumake perl python3 gnum4 bison flex texinfo
    gettext elfutils dwz gdb git hostname-debian gnupg
  ];

  lib' = import ../lib { inherit pkgs lock; installerRpm = rpm; };
  inherit (lib') buildSrpm mkBuildroot rpmTree;

  # ---------------------------------------------------------------- buildroots
  rootLayer = import ./root.nix { inherit pkgs rpm debugedit tools; fhsTrees = [ kh glibc binutils gcc ]; };
  buildroot = rootLayer // { layers = [ rootLayer ]; };

  # dev only: same root without the FHS toolchain, to exercise the runner /
  # mkBuildroot / buildSrpm machinery on noarch packages without waiting for gcc
  devRootLayer = import ./root.nix {
    inherit pkgs rpm debugedit tools; fhsTrees = [ ]; withToolchain = false; name = "stage0-root-dev";
  };
  devBuildroot = devRootLayer // { layers = [ devRootLayer ]; };
  dev = rec {
    buildroot = devBuildroot;
    release = buildSrpm { srpm = "rocky-release"; buildroot = devBuildroot; };
    buildrootRelease = mkBuildroot { name = "dev-release"; base = devBuildroot; rpms = [ release ]; };
    redhat-rpm-config = buildSrpm { srpm = "redhat-rpm-config"; buildroot = buildrootRelease; };
    releaseTree = rpmTree { build = release; name = "rocky-release"; };
  };

  # a) rocky-release, built with plain rpm macros, installed -> %dist, %rhel, %el10 ...
  release = buildSrpm { srpm = "rocky-release"; inherit buildroot; };
  buildrootRelease = mkBuildroot { name = "stage0-release"; base = buildroot; rpms = [ release ]; };

  # b) redhat-rpm-config + the *-srpm-macros it Requires, built twice:
  #    pass A with plain rpm macros (+ macros.dist), pass B inside the buildroot
  #    that pass A produced -- so the final macro packages are built by the
  #    same macro set they ship, like in a real Rocky buildroot.
  macroSrpms = {
    redhat-rpm-config = { names = [ "redhat-rpm-config" ]; };
    efi-rpm-macros = { names = [ "efi-srpm-macros" ]; };
    fonts-rpm-macros = { names = [ "fonts-srpm-macros" ]; };
    forge-srpm-macros = { names = [ "forge-srpm-macros" ]; args = [ "--nocheck" ]; };
    # %ifarch golang_arches needs golang to build the bundled golist; for a
    # non-go arch the spec ships just the (identical) noarch go-srpm-macros
    go-rpm-macros = { names = [ "go-srpm-macros" ]; target = "noarch"; };
    kernel-srpm-macros = { names = [ "kernel-srpm-macros" ]; };
    lua-rpm-macros = { names = [ "lua-srpm-macros" ]; };
    ocaml-srpm-macros = { names = [ "ocaml-srpm-macros" ]; };
    openblas-srpm-macros = { names = [ "openblas-srpm-macros" ]; };
    package-notes = { names = [ "package-notes-srpm-macros" ]; };
    perl-srpm-macros = { names = [ "perl-srpm-macros" ]; };
    pyproject-rpm-macros = { names = [ "pyproject-srpm-macros" ]; args = [ "--nocheck" ]; };
    python-rpm-macros = { names = [ "python-srpm-macros" ]; args = [ "--nocheck" ]; };
    qt6 = { names = [ "qt6-srpm-macros" ]; };
    # rust-srpm-macros comes from the 270 MB rust SRPM: not in stage0 (docs/stage0.md)
  };
  buildMacrosIn = br: set: lib.mapAttrs (n: v: buildSrpm ({
    srpm = n; buildroot = br; rpmbuildArgs = v.args or [ ];
  } // lib.optionalAttrs (v ? target) { inherit (v) target; })) set;
  buildMacros = br: buildMacrosIn br macroSrpms;
  macroRpms = builds: lib.mapAttrsToList (n: v: { from = builds.${n}; inherit (v) names; }) macroSrpms;

  # Pass A in waves: the macro packages use each other's macros at build time
  # (%rpmmacrodir from redhat-rpm-config, %forgemeta from forge-srpm-macros).
  # redhat-rpm-config's %__os_install_post uses %{__os_install_post_python}
  # (python-srpm-macros), so python-rpm-macros' own pass-A build gets it as
  # %{nil} -- the only time it is ever missing.
  wavesA = [ [ "redhat-rpm-config" ] [ "python-rpm-macros" ] [ "forge-srpm-macros" ]
    (lib.subtractLists [ "redhat-rpm-config" "python-rpm-macros" "forge-srpm-macros" ] (builtins.attrNames macroSrpms)) ];
  definesA = { python-rpm-macros = { __os_install_post_python = "%{nil}"; }; };
  passA = lib.foldl' (acc: wave:
    let
      sub = lib.getAttrs wave macroSrpms;
      builds = lib.mapAttrs (n: b: if definesA ? ${n} then buildSrpm ({
        srpm = n; buildroot = acc.br; rpmbuildArgs = sub.${n}.args or [ ]; defines = definesA.${n};
      }) else b) (buildMacrosIn acc.br sub);
    in {
      builds = acc.builds // builds;
      br = mkBuildroot {
        name = "stage0-full-a-${toString (builtins.length (builtins.attrNames acc.builds))}";
        base = acc.br;
        rpms = lib.mapAttrsToList (n: v: { from = builds.${n}; inherit (v) names; }) sub;
      };
    }) { builds = { }; br = buildrootRelease; } wavesA;
  macrosA = passA.builds;
  buildrootFullA = passA.br;
  macros = buildMacros buildrootFullA;
  buildrootFull = mkBuildroot { name = "stage0-full"; base = buildrootRelease; rpms = macroRpms macros; };

  # c) an arch-dependent C package with the full Rocky flags + debuginfo
  which = buildSrpm { srpm = "which"; buildroot = buildrootFull; };

  # d) Rocky kernel-headers: real rpmbuild of the kernel SRPM, headers only
  #    (packages/kernel-headers.nix, docs/kernel-headers.md)
  kernelHeadersPkg = import ../packages/kernel-headers.nix {
    inherit pkgs lib' rpm;
    buildroot = buildrootFull;
    macroRpms = [
      { from = macros.python-rpm-macros; names = [ "python-rpm-macros" "python3-rpm-macros" ]; }
      { from = macros.kernel-srpm-macros; names = [ "kernel-rpm-macros" ]; }
    ];
    officialRpm = if officialRpms != null then officialRpms."kernel-headers.x86_64" else null;
  };
  kernelHeadersBuild = kernelHeadersPkg.build;

  # e) stage0-full with Rocky's kernel-headers *instead of* nixpkgs' headers.
  #    Installing the RPM on top of buildrootFull would leave the 21 headers
  #    that exist only in nixpkgs' 6.18 headers behind (a layer cannot delete
  #    lower files).  So: the same root assembled without nixpkgs' headers
  #    (only /usr/include differs; the toolchain derivations are untouched),
  #    the unchanged release/macro layers of buildrootFull stacked on it (none
  #    of them touches /usr/include), then kernel-headers installed with rpm
  #    -- registered in the rpmdb, as glibc.spec's `rpm -ql kernel-headers`
  #    needs.  docs/kernel-headers.md.
  rootLayerNoKh = import ./root.nix {
    inherit pkgs rpm debugedit tools; fhsTrees = [ glibc binutils gcc ]; name = "stage0-root-nokh";
  };
  buildrootFullKernelHeaders = mkBuildroot {
    name = "stage0-full-kernel-headers";
    base = buildrootFull // { layers = [ rootLayerNoKh ] ++ lib.tail buildrootFull.layers; };
    rpms = [ kernelHeadersPkg.rpmSpec ];
  };

  srpmBuilds = { rocky-release = release; inherit which; kernel = kernelHeadersBuild; } // macros;

  # binary rpm name -> extracted tree (d)
  produces = {
    rocky-release = [ "rocky-release" "rocky-repos" "rocky-gpg-keys" "rocky-sb-certs" ];
    which = [ "which" ];
    kernel = [ "kernel-headers" ];
  } // lib.mapAttrs (n: v: v.names) macroSrpms;
  rpms = lib.foldl' (acc: s: acc // lib.genAttrs produces.${s} (name: rpmTree { build = srpmBuilds.${s}; inherit name; }))
    { } (builtins.attrNames produces);

  tests = import ./tests { inherit pkgs lib' buildroot buildrootFull which rpms; }
    // {
      kernelHeadersBuildroot = lib'.runInBuildroot {
        name = "stage0-test-kernel-headers-buildroot";
        buildroot = buildrootFullKernelHeaders;
        script = builtins.readFile ./tests/kernel-headers.sh;
      };
      # the full toolchain acceptance test again, on the Rocky headers
      toolchainKernelHeaders = lib'.runInBuildroot {
        name = "stage0-test-toolchain-kernel-headers";
        buildroot = buildrootFullKernelHeaders;
        script = builtins.readFile ./tests/toolchain.sh;
      };
    } // lib.optionalAttrs (officialRpms != null) { kernelHeaders = kernelHeadersPkg.check; };

  # ---------------------------------------------------------------- package roots
  # A root layer like `buildroot` (same toolchain, rpm, nixpkgs tools, /etc)
  # with different kernel headers and/or extra FHS trees (e.g. -devel
  # libraries a package needs).  kernelHeaders = null: none -- the caller
  # installs a kernel-headers RPM on top (then `rpm -ql kernel-headers` works).
  # Only the cheap root derivation differs; the toolchain is not rebuilt.
  mkRoot = { name, kernelHeaders ? kh, extraTrees ? [ ] }:
    let
      l = import ./root.nix {
        inherit pkgs rpm debugedit tools name;
        fhsTrees = lib.optional (kernelHeaders != null) kernelHeaders ++ [ glibc binutils gcc ] ++ extraTrees;
      };
    in l // { layers = [ l ]; };
  # what stage0-full installs on top of the root: rocky-release + the pass-B
  # macro packages (mkBuildroot rpm specs)
  fullRpms = [ release ] ++ macroRpms macros;

  # glibc SRPM build inputs missing from the stage0 root (docs/glibc.md)
  glibcBuildDeps = import ./glibc-build-deps.nix { inherit pkgs; systemtapSrpm = srpm "systemtap"; };
in
{
  inherit binutils gccPass1 glibc sysroot gcc rpm debugedit;
  kernelHeaders = kh;
  # Rocky kernel-headers (buildSrpm result of the kernel SRPM, headers only);
  # for mkBuildroot: rpms = [ { from = kernelHeadersBuild; names = [ "kernel-headers" ]; } ]
  inherit kernelHeadersBuild;
  inherit (kernelHeadersPkg) buildrootKernel;
  inherit buildrootFullKernelHeaders;
  inherit buildroot buildrootRelease buildrootFullA buildrootFull;
  srpm = srpmBuilds;
  srpmPassA = macrosA;
  inherit rpms tests dev;
  inherit mkRoot fullRpms glibcBuildDeps;
  lib = lib';
  # helper for later packages: build an SRPM from the lock in the full stage0 buildroot
  buildStage0 = args: buildSrpm ({ buildroot = buildrootFull; } // args);
}
