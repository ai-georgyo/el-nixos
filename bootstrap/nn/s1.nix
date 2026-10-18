# Stage S1, the boot toolchain stage (docs/nix-native-design.md §6):
# relocated, split SRPM builds (mkRpmPackage) made with
#   * stdenv  = nixpkgs' stdenvNoCC (bootstrap tooling only; nothing it
#     contains may end up in an output: outputChecks enforce it),
#   * cc      = nn.cc.wrap over copies of the stage0 gcc 14.3.1 / binutils 2.41,
#   * rpm     = the stage0 rpm 4.19.1.1 (FHS tree, /usr/bin/rpmbuild through
#     the view) with nn.rpmConfig (stage0's redhat-rpm-config, *-srpm-macros,
#     rocky-release macros),
#   * libc    = nn.cc.stage0Libc (the stage0 glibc relocated into one store
#     path, + Rocky kernel-headers) for glibc¹ itself AND, for now, for every
#     other S1 package:
#       - glibc¹ (rockyBoot.s1.glibc, WP7) does not exist yet, and the design's
#         "then glibc¹" step needs it verified first (M1);
#       - `glibc1 = true` switches every S1 package except glibc and
#         kernel-headers to wrap { libc = rockyBoot.s1.glibc } (the design's
#         order: kernel-headers, glibc¹, then the rest);
#       - consequence while it is false: the outputs reference the stage0 libc
#         tree (PT_INTERP, RUNPATH): the named S1 exception `stage0LibcTree`.
#         Its loader has the FHS system dirs compiled in, so libc.so.6 is found
#         through RUNPATH (the partitioner keeps <stage0Libc>/lib64 from
#         inputLibDirs; systemLibDirs is empty).
#
# BuildRequires (lock builddeps.json) map to S1 packages where S1 builds the
# provider, else to the explicit fallback set below (build-only: tools on
# PATH, never runtime inputs, never in an output), else evaluation fails.
# glibc uses no S1 package (only kernel-headers through its inputs.add):
# every other S1 package links the stage0 libc, and glibc¹'s closure must not
# contain it.
#
# Exposed (lib/rocky/parts/rockyBoot.nix): rockyBoot.s1.<srpm> (packages),
# nn.stages.s1 (the stage: pkgs, rpm.<rpm-name>, glibcBuildDeps,
# libgccForGlibc, resolveBuildDeps, ...).
{ bootPkgs, lib, lock, stage0, nn, fetch, mkStage, glibc1 ? false }:
let
  pkgs = bootPkgs;
  s0 = stage0;

  # ---- named S1 exceptions -------------------------------------------------
  stage0Libc = nn.cc.stage0Libc;
  stage0LibcTree = stage0Libc.out;
  libgccForGlibc = nn.libgccForGlibc;

  # glibc¹ in the shape the wrapper wants (lib/rocky/cc/wrap.nix libcAdapter)
  glibc1Libc = nn.cc.libcAdapter { out = self.pkgs.glibc.out; dev = self.pkgs.glibc.dev; };
  usesStage0Libc = srpm: !glibc1 || lib.elem srpm [ "glibc" "kernel-headers" ];
  libcFor = srpm: if usesStage0Libc srpm then stage0Libc else glibc1Libc;
  ccStage0 = nn.cc.stage0;
  ccGlibc1 = nn.cc.wrap { libc = glibc1Libc; name = "rocky-s1-glibc1"; };

  # ---- build-only helper trees ---------------------------------------------
  # redhat-rpm-config's brp-ldconfig runs /sbin/ldconfig -N -r BUILDROOT: the
  # stage0 (Rocky-source, static) one; nixpkgs' is patched and fails with -r
  ldconfig = pkgs.runCommand "s1-stage0-ldconfig" { } ''
    mkdir -p $out/bin; ln -s ${s0.glibc}/usr/sbin/ldconfig $out/bin/ldconfig
  '';
  # %gpgverify runs gpgv2 (Rocky's gnupg2 name)
  gpgv2 = pkgs.runCommand "s1-gpgv2" { } ''
    mkdir -p $out/bin; ln -s ${pkgs.gnupg}/bin/gpgv $out/bin/gpgv2
  '';
  # bin/ of an FHS-in-store tree (usr/bin) for PATH
  fhsBin = name: tree: pkgs.runCommand "s1-${name}-bin" { } ''
    mkdir -p $out/bin; for f in ${tree}/usr/bin/*; do ln -s $f $out/bin/; done
  '';
  # Rocky's texinfo 7.1 (stage0, FHS): makeinfo/texi2any read
  # /usr/share/texinfo, so the tree is also in the view
  texinfo = { native = [ (fhsBin "texinfo" s0.texinfo71) ]; view = [ s0.texinfo71 ];
              reason = "stage0 texinfo 7.1 (Rocky source, FHS)"; };
  # cmake-rpm-macros (%cmake, %cmake_build, %ctest): Rocky's macros.cmake.in
  # from the locked cmake SRPM, substituted as cmake.spec's %install does
  cmakeRpmMacros =
    let e = lock.srpms.cmake; major = lib.head (lib.splitString "." e.version); in
    pkgs.runCommand "s1-cmake-rpm-macros-${e.version}-${e.release}" { nativeBuildInputs = [ pkgs.libarchive ]; } ''
      mkdir -p $out
      bsdtar -xOf ${fetch.fetchSrpm "cmake"} cmake.spec > cmake.spec
      grep -q 'sed -i -e "s|@@CMAKE_VERSION@@|%{version}|" -e "s|@@CMAKE_MAJOR_VERSION@@|%{major_version}|"' cmake.spec
      bsdtar -xOf ${fetch.fetchSrpm "cmake"} macros.cmake.in \
        | sed -e "s|@@CMAKE_VERSION@@|${e.version}|" -e "s|@@CMAKE_MAJOR_VERSION@@|${major}|" > $out/macros.cmake
      grep -q '^%cmake_build' $out/macros.cmake
    '';

  # glibc's -devel build deps (gd, libpng, zlib, libselinux, audit, libcap,
  # sdt.h) from stage0 (nixpkgs-built), hoisted to the store layout; S1 only,
  # build-only (memusagestat/makedb NEED them unresolved: allowUnresolvedNeeded)
  glibcBuildDeps = pkgs.runCommand "s1-glibc-build-deps" { } ''
    mkdir -p $out
    for d in include lib64 lib bin; do
      if [ -e ${s0.glibcBuildDeps}/usr/$d ]; then mkdir -p $out/$d; cp -rs ${s0.glibcBuildDeps}/usr/$d/. $out/$d/; fi
    done
  '';

  # Rocky's kernel headers in the store layout ($out/include), INTERIM until
  # WP8's rockyBoot.s1.kernel-headers (from the kernel SRPM, headers-only
  # recipe) replaces this entry
  kernelHeadersInterim = pkgs.runCommand "kernel-headers-interim-${lock.srpms.kernel.version}-${lock.srpms.kernel.release}" {
    passthru = { rockyStage = "s0"; interim = true; };
  } ''
    mkdir -p $out
    cp -a ${s0.rpms.kernel-headers}/usr/include $out/
  '';

  drop = reason: { drop = reason; };
  tool = ps: reason: { native = ps; inherit reason; };

  # ---- the fallback set: every BuildRequire S1 does not build --------------
  fallback = with pkgs; {
    # the stage cc (wrapper over the stage0 gcc/binutils copies)
    gcc = drop "the stage cc";
    "gcc-c++" = drop "the stage cc (g++)";
    cpp = drop "the stage cc";
    binutils = drop "the stage cc's binutils";
    "libstdc++-static" = drop "the stage cc's gcc copy has libstdc++.a";
    "libstdc++" = drop "the stage cc's gcc copy";
    "glibc-static" = drop "the stage libc tree has the static archives";
    "glibc-devel" = drop "the stage libc (cc-wrapper libc + view)";
    # rpmbuild environment tools that are in baseTools already
    make = drop "baseTools (GNU make)";
    sed = drop "baseTools";
    gawk = drop "baseTools";
    diffutils = drop "baseTools";
    coreutils = drop "baseTools";
    findutils = drop "baseTools";
    tar = drop "baseTools";
    bzip2 = drop "baseTools";
    xz = drop "baseTools";
    bash = drop "baseTools";
    "util-linux" = drop "baseTools";
    "procps-ng" = drop "baseTools";
    "perl-interpreter" = drop "baseTools (perl)";
    perl = drop "baseTools (perl)";
    python3 = drop "baseTools (python3)";
    gdb = drop "baseTools (gdb, find-debuginfo's gdb-add-index)";
    gnupg2 = drop "baseTools (gpgv2 for %gpgverify)";
    hostname = drop "baseTools";
    which = drop "baseTools";
    # nixpkgs tools (build-only)
    autoconf = tool [ autoconf ] "nixpkgs autoconf";
    automake = tool [ automake ] "nixpkgs automake";
    libtool = tool [ libtool ] "nixpkgs libtool";
    gettext = tool [ gettext ] "nixpkgs gettext";
    "gettext-devel" = tool [ gettext ] "nixpkgs gettext (autopoint, m4 macros; libintl is glibc's)";
    bison = tool [ bison ] "nixpkgs bison";
    flex = tool [ flex ] "nixpkgs flex";
    m4 = tool [ gnum4 ] "nixpkgs m4";
    less = tool [ less ] "nixpkgs less";
    git = tool [ git ] "nixpkgs git";
    "git-core" = tool [ git ] "nixpkgs git";
    bc = tool [ bc ] "nixpkgs bc";
    texinfo = texinfo;
    cmake = { native = [ cmake ]; macroDirs = [ "${cmakeRpmMacros}" ];
              reason = "nixpkgs cmake + Rocky's macros.cmake (cmake-rpm-macros)"; };
    # not needed with --nocheck
    libabigail = drop "%check only (abicheck.sh)";
    valgrind = drop "%check only";
    dejagnu = drop "%check only";
    # which: Rocky's which NEEDs only libc.so.6 (official which-2.21-44.el10_0)
    "readline-devel" = drop "which links no readline (official binary NEEDs libc.so.6 only)";
    # glibc¹: its -devel deps come from glibcBuildDeps / kernel-headers (inputs.add)
    "audit-libs-devel" = drop "glibc: glibcBuildDeps";
    "gd-devel" = drop "glibc: glibcBuildDeps";
    "libpng-devel" = drop "glibc: glibcBuildDeps";
    "libselinux-devel" = drop "glibc: glibcBuildDeps";
    "libcap-devel" = drop "glibc: glibcBuildDeps";
    "zlib-ng-compat-devel" = drop "glibc: glibcBuildDeps (S1's zlib-ng links the stage0 libc)";
    "systemtap-sdt-devel" = drop "glibc: glibcBuildDeps (sdt.h)";
    "kernel-headers" = drop "glibc: inputs.add (stage.pkgs.kernel-headers)";
    libidn2 = drop "glibc: dlopen'ed at run time only";
    "python3-devel" = drop "baseTools (python3)";
  };

  self = mkStage {
    name = "s1";
    stdenv = pkgs.stdenvNoCC;
    ccFor = srpm: if usesStage0Libc srpm then ccStage0 else ccGlibc1;
    inherit libcFor;
    # the stage0 libc's loader searches only FHS dirs: no system dir in the
    # store; with glibc¹ its lib64 is the loader's system dir
    systemLibDirs = srpm: if usesStage0Libc srpm then [ ] else [ "${self.pkgs.glibc.out}/lib64" ];
    baseTools = with pkgs; [
      bash coreutils gnused gnugrep gawk findutils diffutils gnupatch gnutar gzip bzip2 xz zstd
      cpio s0.rpmLibs.file util-linux procps gnumake perl elfutils dwz gdb hostname-debian which
      ldconfig gpgv2 gnupg
    ];
    fhsBins = [ "${s0.rpm}/usr/bin" "${s0.debugedit}/usr/bin" ];
    rpm = s0.rpm;
    rpmFhs = true;
    rpmConfig = nn.rpmConfig;
    toolShim = nn.toolShim;
    inherit (pkgs) patchelf python3;
    bsdtar = pkgs.libarchive;
    fhsPath = true;
    # no annobin plugin for the stage0 gcc copy: rpmConfig empties
    # %_annobin_gcc_plugin (redhat-rpm-config only tests definedness), and
    # specs that test the value (glibc: `0%{?_annotated_build} > 0` adds
    # -fplugin=annobin to BuildFlagsNonshared) see 0, as in M1 (docs/glibc.md)
    defines = { _annotated_build = "0"; };
    inherit fallback;
    # named S1 exception (design §1.4.3: fhsAllowlist, bootstrap only):
    # brp-mangle-shebangs writes Rocky's `#!/usr/bin/sh`, and S1 has no Rocky
    # shell that patchShebangs could bind it to (nixpkgs' bash must not enter
    # an output).  The scripts (gzip's gunzip/zcat/zgrep/..., xz's
    # xzgrep/xzdiff/xzless/xzmore) therefore need /usr/bin/sh at run time:
    # they do NOT run on NixOS or in a sandbox without /usr; the ELF programs
    # do.  Bound once a stage has a Rocky bash as a runtime input (S2+).
    # Every other unbound FHS shebang fails the build (--check-shebangs).
    fhsAllowlist = {
      "#!/usr/bin/sh" = "S1 bootstrap exception: no Rocky shell to bind /usr/bin/sh to (needs /usr/bin/sh at run time)";
    };
    # glibc uses no S1 package (see the header)
    usesStagePackage = srpm: _provider: srpm != "glibc";
    exceptionsFor = srpm:
      if srpm == "glibc" then [ libgccForGlibc ]
      else if usesStage0Libc srpm then [ stage0LibcTree ]
      else [ ];
    # the design's S1 list is longer (macro packages, gmp, mpfr, libmpc, zstd,
    # binutils¹, gcc¹): each needs its fallback entries / overrides first
    # (docs/research/nix-native/experiments/wp6.md)
    packages = [ "glibc" "which" "xz" "zlib-ng" "gzip" ];
    extraPkgs = _: { kernel-headers = kernelHeadersInterim; };
    extra = self': {
      inherit glibcBuildDeps libgccForGlibc stage0Libc stage0LibcTree cmakeRpmMacros glibc1;
      fallbackReasons = lib.mapAttrs (_: v: v.reason or v.drop) fallback;
    };
  };
in
self
