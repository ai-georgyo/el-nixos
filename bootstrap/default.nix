# stage0: an FHS buildroot synthesized from nixpkgs + Rocky toolchain sources,
# then completed with Rocky's own release/macro packages built from SRPMs.
# See docs/stage0.md.
{ pkgs                    # nixpkgs (bootstrap only)
, lock                    # parsed lock/rocky-<rel>/srpms.json
, kernelHeaders ? null    # FHS tree with usr/include/{linux,asm,...}; default: nixpkgs linuxHeaders
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
  # libc + kernel headers laid out as a root, for gcc's --with-build-sysroot
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
  buildMacros = br: lib.mapAttrs (n: v: buildSrpm ({
    srpm = n; buildroot = br; rpmbuildArgs = v.args or [ ];
  } // lib.optionalAttrs (v ? target) { inherit (v) target; })) macroSrpms;
  macroRpms = builds: lib.mapAttrsToList (n: v: { from = builds.${n}; inherit (v) names; }) macroSrpms;

  macrosA = buildMacros buildrootRelease;
  buildrootFullA = mkBuildroot { name = "stage0-full-a"; base = buildrootRelease; rpms = macroRpms macrosA; };
  macros = buildMacros buildrootFullA;
  buildrootFull = mkBuildroot { name = "stage0-full"; base = buildrootRelease; rpms = macroRpms macros; };

  # c) an arch-dependent C package with the full Rocky flags + debuginfo
  which = buildSrpm { srpm = "which"; buildroot = buildrootFull; };

  srpmBuilds = { rocky-release = release; inherit which; } // macros;

  # binary rpm name -> extracted tree (d)
  produces = {
    rocky-release = [ "rocky-release" "rocky-repos" "rocky-gpg-keys" "rocky-sb-certs" ];
    which = [ "which" ];
  } // lib.mapAttrs (n: v: v.names) macroSrpms;
  rpms = lib.foldl' (acc: s: acc // lib.genAttrs produces.${s} (name: rpmTree { build = srpmBuilds.${s}; inherit name; }))
    { } (builtins.attrNames produces);

  tests = import ./tests { inherit pkgs lib' buildroot buildrootFull which rpms; };
in
{
  inherit binutils gccPass1 glibc sysroot gcc rpm debugedit;
  kernelHeaders = kh;
  inherit buildroot buildrootRelease buildrootFullA buildrootFull;
  srpm = srpmBuilds;
  srpmPassA = macrosA;
  inherit rpms tests dev;
  lib = lib';
  # helper for later packages: build an SRPM from the lock in the full stage0 buildroot
  buildStage0 = args: buildSrpm ({ buildroot = buildrootFull; } // args);
}
