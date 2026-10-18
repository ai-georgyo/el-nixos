# mkStage (docs/nix-native-design.md §11.2, §5.6, §6): one bootstrap stage
# as a lazy fixpoint.
#
#   mkStage {
#     name                    "s1", "s2", ...
#     stdenv                  the stage's generic stdenv (no cc: mkRpmPackage
#                             puts the stage cc first on PATH itself)
#     ccFor srpm              the wrapped C/C++ toolchain building srpm
#     libcFor srpm            the libc the wrapper links against ({ out; dev; })
#     libcSrpm ? "glibc"      the SRPM that IS the libc: its programs find libc in
#                             their own system dir (no libc runtime input, its
#                             systemLibDirs are @out@/lib64 @out@/lib)
#     systemLibDirs ? srpm: [ ]   the stage libc's loader dirs (sonames found there
#                             get no RUNPATH entry); the stage0 libc's loader has
#                             FHS dirs only, so S1 packages keep RUNPATH to it
#     baseTools               build-only tools on PATH for every package (rpmbuild
#                             environment: shell, coreutils, cpio, find-debuginfo's
#                             helpers, ...), listed explicitly
#     fhsBins ? [ ]           FHS bin dirs appended to PATH (stage0 rpm, debugedit)
#     rpm  rpmFhs ? false     the rpm package; rpmBin/rpmLibDir default to its
#                             FHS (usr/, rpmFhs) or relocated layout
#     rpmConfig               lib/rocky/rpm/config.nix instance (+ .configSite)
#     toolShim  patchelf  python3  bsdtar   build tools of the builder itself
#     fhsPath ? true          run rpmbuild with PATH=/usr/bin (the view), so
#                             configure records FHS interpreter paths that
#                             patchShebangs/lateBind bind later (§5.4); false =
#                             the store PATH
#     fallback ? { }          BuildRequires (rpm names) the stage does not build:
#                             <rpm> = { native ? [ ]; host ? [ ]; view ? [ ];
#                                       macroDirs ? [ ]; reason; }
#                             (build-only: never runtime inputs) or
#                             <rpm> = { drop = "<reason>"; }
#     usesStagePackage ? srpm: provider: true
#                             false: srpm's BuildRequires provided by that stage
#                             package go to the fallback set instead (S1: glibc¹
#                             must not link the S1 packages built on stage0's libc)
#     exceptionsFor ? srpm: [ ]   store paths allowed in srpm's output closures
#                             besides its own outputs and its runtime inputs'
#                             (named bootstrap exceptions, §6)
#     buildPure ? false       eval-time build-purity assertion (S3/S4)
#     packages                SRPM names built by mkRpmPackage in this stage
#     extraPkgs ? self: { }   other stage packages (not SRPM-built, or interim)
#     extra ? self: { }       anything else the stage exposes (glibcBuildDeps,
#                             libgccForGlibc, ...)
#     mkRpmPackage purity overridesFor builddeps   (from lib/rocky/parts/mkStage.nix)
#   }
#
# Result (fixpoint `self`):
#   name stdenv stdenvNoCC buildPure rpmPkg (the rpm package) rpmBin rpmLibDir
#   pkgs.<srpm>               mkRpmPackage self { srpm } (+ extraPkgs)
#   rpm.<rpm-name>            the output of a stage package holding that shipped RPM
#   resolveBuildDeps srpm inputs -> { native host view macro macroDirs runtime
#                                     dropped fromStage fromFallback }
#   ccFor libcFor runtimeLibcFor libcDevFor systemLibDirsFor exceptionsFor
#   allowedBuildDrvs purityChecker overridesFor tools ...
#
# resolveBuildDeps (§5.6): builddeps.json `inputs` (direct providers of the
# BuildRequires) minus inputs.drop, each one
#   * built by this stage (provider SRPM in `packages`): its output, by tag
#       lib   -> host (cc-wrapper input, view, runtime input)
#       macro -> macro (lib/rpm/macros.d -> NIX_RPM_MACRO_DIRS) and native
#       tool  -> native (PATH; relocated tools find their own data)
#     The `-devel`-style host output brings its SRPM's out/lib outputs along
#     (static Requires are not in the lock yet; see wp6.md).
#   * else the stage fallback (build-only), else an evaluation error listing
#     every unmapped name with its provider SRPM.
# plus inputs.add (host; runtime only if Rocky-built, i.e. it has
# rockyRequisites) and inputs.addNative (native).
{ lib, names, readLock }:
{ name
, stdenv
, ccFor
, libcFor
, libcSrpm ? "glibc"
, systemLibDirs ? (srpm: [ ])
, baseTools
, fhsBins ? [ ]
, rpm
, rpmFhs ? false
, rpmBin ? (if rpmFhs then "${rpm}/usr/bin/rpm" else "${rpm}/bin/rpm")
, rpmLibDir ? (if rpmFhs then "${rpm}/usr/lib/rpm" else "${rpm}/lib/rpm")
, rpmConfig
, toolShim
, patchelf
, python3
, bsdtar
, fhsPath ? true
, fallback ? { }
, usesStagePackage ? (srpm: provider: true)
, exceptionsFor ? (srpm: [ ])
, buildPure ? false
, packages
, extraPkgs ? (self: { })
, extra ? (self: { })
, mkRpmPackage
, purity
, overridesFor
, builddeps ? readLock "builddeps.json"
, subpackages ? names.subpackages
}:
let
  self = {
    inherit name stdenv buildPure fhsPath rpmBin rpmLibDir rpmConfig toolShim patchelf
      python3 bsdtar fhsBins ccFor libcFor libcSrpm exceptionsFor purity fallback packages;
    stdenvNoCC = stdenv;
    rpmPkg = rpm;   # the rpm package (`rpm` is the RPM-name alias set)
    baseTools = baseTools ++ [ python3 bsdtar ];

    runtimeLibcFor = srpm: if srpm == libcSrpm then null else (libcFor srpm).out;
    libcDevFor = srpm: (libcFor srpm).dev;
    systemLibDirsFor = srpm:
      if srpm == libcSrpm then [ "@out@/lib64" "@out@/lib" ] else systemLibDirs srpm;

    overridesFor = overridesFor { stage = self; };

    pkgs = lib.genAttrs packages (srpm: mkRpmPackage self { inherit srpm; }) // extraPkgs self;

    # shipped RPM name -> output of the stage package (keys from the lock
    # only, so listing them forces no package evaluation)
    rpm = lib.listToAttrs (lib.concatMap (srpm:
      let s = subpackages.${srpm} or { names = [ ]; shipped = { }; }; in
      map (n: lib.nameValuePair n (let p = self.pkgs.${srpm}; in p.${p.rpmOutputs.${n}}))
        (lib.filter (n: s.shipped.${n} or false) s.names)) packages);

    resolveBuildDeps = srpm: inputs:
      let
        b = builddeps.srpms.${srpm} or { inputs = [ ]; };
        wanted = lib.subtractLists inputs.drop (b.inputs or [ ]);
        providerOf = r: builddeps.providers.${r} or { srpm = null; tags = [ "other" ]; };
        inStage = r: let p = providerOf r; in
          p.srpm != null && lib.elem p.srpm packages && p.srpm != srpm && usesStagePackage srpm p.srpm;
        fromStage = lib.filter inStage wanted;
        rest = lib.filter (r: !(inStage r)) wanted;
        unmapped = lib.filter (r: !(fallback ? ${r})) rest;
        fbs = map (r: fallback.${r}) (lib.filter (r: fallback ? ${r} && !(fallback.${r} ? drop)) rest);
        dropped = lib.filter (r: fallback ? ${r} && fallback.${r} ? drop) rest;

        stageOut = r:
          let p = self.pkgs.${(providerOf r).srpm}; in p.${p.rpmOutputs.${r} or "out"};
        # a library input brings the outputs that hold the runtime libraries
        withLibs = r:
          let
            p = self.pkgs.${(providerOf r).srpm};
            o = stageOut r;
          in lib.unique ([ o ] ++ map (x: p.${x}) (lib.filter (x: lib.elem x p.outputs) [ "out" "lib" ]));
        tagged = t: lib.filter (r: lib.elem t (providerOf r).tags) fromStage;
        libsR = tagged "lib";
        macroR = tagged "macro";
        toolR = lib.filter (r: !(lib.elem r libsR) && !(lib.elem r macroR)) fromStage;

        stageHost = lib.unique (lib.concatMap withLibs libsR);
        stageMacro = map stageOut macroR;
        stageNative = map stageOut toolR;
        isRocky = d: d ? rockyRequisites;
        addRocky = lib.filter isRocky inputs.add;
        addOther = lib.filter (d: !(isRocky d)) inputs.add;
      in
      if unmapped != [ ] then
        throw ("stage ${name}: ${srpm}: BuildRequires providers neither built by the stage nor in its fallback set: "
          + lib.concatMapStringsSep ", " (r: "${r} (SRPM ${toString (providerOf r).srpm})") unmapped
          + "; add them to the stage's `packages`, its `fallback`, or the package's inputs.drop")
      else {
        native = stageNative ++ stageMacro ++ lib.concatMap (f: f.native or [ ]) fbs ++ inputs.addNative;
        host = stageHost ++ inputs.add ++ lib.concatMap (f: f.host or [ ]) fbs;
        # libraries/headers reachable through /usr (and the $out alias): host
        # inputs only (every one is also a cc-wrapper input)
        view = stageHost ++ inputs.add ++ lib.concatMap (f: f.view or [ ]) fbs;
        macro = stageMacro;
        macroDirs = lib.concatMap (f: f.macroDirs or [ ]) fbs;
        # what the outputs may reference (rockyRequisites of these)
        runtime = stageHost ++ addRocky;
        buildOnly = addOther;
        inherit dropped fromStage;
        fromFallback = lib.filter (r: fallback ? ${r} && !(fallback.${r} ? drop)) rest;
        unresolved = b.unresolved or [ ];
      };

    # the derivations a build in this stage may depend on (§7.3)
    allowedBuildDrvs = purity.drvSet (lib.attrValues self.pkgs ++ self.baseTools ++ [ toolShim patchelf ]);
    purityChecker = purity.forStage self;
  } // extra self;
in
self
