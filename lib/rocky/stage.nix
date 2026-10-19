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
#     rpmConfigWith ? macroPkgs: rpmConfig { inherit macroPkgs; }
#                             the stage's rpm config plus whole macro package
#                             trees (fallback `macroPkgs`); used by the packages
#                             whose inputs bring such trees, the others share
#                             rpmConfig
#     toolShim  patchelf  python3  bsdtar   build tools of the builder itself
#     fhsPath ? true          run rpmbuild with PATH=/usr/bin (the view), so
#                             configure records FHS interpreter paths that
#                             patchShebangs/lateBind bind later (§5.4); false =
#                             the store PATH
#     defines ? { }           rpmbuild --define for every package of the stage
#                             (a package's own `defines` win)
#     fallback ? { }          BuildRequires (rpm names) the stage does not build:
#                             <rpm> = { native ? [ ]; host ? [ ]; view ? [ ];
#                                       macroDirs ? [ ]; macroPkgs ? [ ]; reason; }
#                             (build-only: never runtime inputs; macroDirs:
#                             macros.d dirs; macroPkgs: whole macro package
#                             trees -- lib/rpm or usr/lib/rpm with redhat/
#                             scripts and fileattrs -- merged into a per-package
#                             rpm config, rpmConfigWith) or
#                             <rpm> = { drop = "<reason>"; }
#     usesStagePackage ? srpm: provider: true
#                             false: srpm's BuildRequires provided by that stage
#                             package go to the fallback set instead (S1: glibc¹
#                             must not link the S1 packages built on stage0's libc)
#     exceptionsFor ? srpm: [ ]   store paths allowed in srpm's output closures
#                             besides its own outputs and its runtime inputs'
#                             (named bootstrap exceptions, §6)
#     buildPure ? false       eval-time build-purity assertion (S3/S4)
#     prev ? null             the previous stage: its pkgs are allowed build
#                             inputs (§6 "each stage uses only the previous stage
#                             and itself", §7.3)
#     transparent ? [ ]       extra derivations the purity check descends into
#                             (the ccFor wrappers of every package are added)
#     extraAllowedSources ? [ ]   store-path strings of filtered sources a build
#                             may name (rocky-partition's fileset is added)
#     fhsAllowlist ? { }      stage-wide FHS shebangs allowed in outputs
#                             ("#!/usr/bin/sh" = "<reason>"), merged under the
#                             package's own; bootstrap stages only (an error
#                             with buildPure), design §1.4.3 / decision 11
#     lateBindFor ? srpm: false   whether this stage applies a package's
#                             `lateBind` (design §2.9, §11.1, §11.3): true =
#                             pkgs.<srpm> is lateBind.wrap of the raw build
#                             (bound copies of the late outputs and their
#                             referrers); false = the raw build (bootstrap
#                             stages without Rocky interpreters/libs to bind
#                             to: S1; the package then names its FHS shebangs
#                             and unresolved NEEDED as exceptions)
#     lateBindPkgs ? { }      SRPM name -> package for lateBind `libs` not in
#                             pkgs (default: pkgs.<srpm>)
#     interpreterPkgs ? { }   shebang basename -> package for lateBind
#                             `interpreters` (default: pkgs.<SRPM of it>,
#                             lateBind.interpreterSrpm)
#     packages                SRPM names built by mkRpmPackage in this stage
#     variants ? { }          { <attr> = <srpm>; }: further mkRpmPackage builds of
#                             an SRPM under another name, with the override file
#                             packages/<attr>/default.nix (bconds +
#                             builtSubpackages: e.g. kernel-headers = "kernel",
#                             the kernel spec headers-only).  pkgs.<attr>; rpm.*
#                             aliases for its built shipped subpackages; a
#                             BuildRequire it builds resolves to it when the
#                             SRPM itself is not in `packages`
#     extraPkgs ? self: { }   other stage packages (not SRPM-built, or interim)
#     extra ? self: { }       anything else the stage exposes (glibcBuildDeps,
#                             libgccForGlibc, ...)
#     mkRpmPackage purity overridesFor partitionTool builddeps
#                             (from lib/rocky/parts/mkStage.nix)
#   }
#
# Result (fixpoint `self`):
#   name stdenv stdenvNoCC buildPure rpmPkg (the rpm package) rpmBin rpmLibDir
#   pkgs.<srpm>               mkRpmPackage self { srpm } (+ extraPkgs)
#   rpm.<rpm-name>            the output of a stage package holding that shipped RPM
#   resolveBuildDeps srpm inputs -> { native host view macro macroDirs macroPkgs
#                                     runtime dropped fromStage fromFallback }
#   ccFor libcFor runtimeLibcFor libcDevFor systemLibDirsFor exceptionsFor
#   allowedBuildDrvs purityChecker overridesFor tools ...
#
# resolveBuildDeps (§5.6): builddeps.json `inputs` (direct providers of the
# BuildRequires) minus inputs.drop, each one
#   * built by this stage (provider SRPM in `packages`): its output, by tag
#       lib   -> host (cc-wrapper input, view, runtime input)
#       macro -> macro (lib/rpm/macros.d -> NIX_RPM_MACRO_DIRS) and native
#       tool  -> native (PATH; relocated tools find their own data)
#     A `<base>-devel` host output brings the outputs of `<base>` and
#     `<base>-libs` of its SRPM along (passthru.rockyCompanions: where its
#     lib*.so links point; static, Rocky's naming -- the lock has no
#     Requires), so those are runtime inputs too (`runtime`: exactly the
#     outputs used, never the whole package, §7.1).
#   * else the stage fallback (build-only), else an evaluation error listing
#     every unmapped name with its provider SRPM.
# BuildRequires the lock could not resolve (builddeps.json `unresolved`, e.g.
# zlib-ng's cmake(GTest)) must be named in inputs.drop or the fallback set
# (with a reason), else evaluation fails too.
# plus inputs.add (host; runtime only if Rocky-built, i.e. it has
# rockyRequisites; companions as above), inputs.addBuildOnly (host and view,
# never runtime, even when Rocky-built: glibc's kernel-headers) and
# inputs.addNative (native).
# inputs.buildRequires are extra BuildRequires (RPM names) resolved exactly
# like the lock's: what a spec gets in Rocky's buildroot that builddeps.json
# does not list (a BuildRequire's own Requires, a conditional the lock's
# default-bcond parse missed).
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
, rpmConfigWith ? (macroPkgs: rpmConfig { inherit macroPkgs; })
, toolShim
, patchelf
, python3
, bsdtar
, fhsPath ? true
, defines ? { }
, fallback ? { }
, usesStagePackage ? (srpm: provider: true)
, exceptionsFor ? (srpm: [ ])
, buildPure ? false
, prev ? null
, transparent ? [ ]
, extraAllowedSources ? [ ]
, fhsAllowlist ? { }
, lateBindFor ? (srpm: false)
, lateBindPkgs ? { }
, interpreterPkgs ? { }
, packages
, variants ? { }
, extraPkgs ? (self: { })
, extra ? (self: { })
, mkRpmPackage
, purity
, overridesFor
, partitionTool
, builddeps ? readLock "builddeps.json"
, subpackages ? names.subpackages
}:
let
  # Rocky outputs a host input `d` (an output of a mkRpmPackage result) brings
  # along: itself + its companions (<base>-devel -> <base>, <base>-libs)
  linkOutputs = d:
    if d ? rockyCompanions then
      [ d ] ++ map (o: d.rockyOutputsByName.${o}) (d.rockyCompanions.${d.outputName or "out"} or [ ])
    else [ d ];
  # dedup by store path, first occurrence kept, order preserved (lib.unique
  # compares whole values, O(n^2); listToAttrs keeps the first of a name)
  uniqPaths = l:
    let
      key = p: builtins.unsafeDiscardStringContext (toString p);
      first = lib.listToAttrs (lib.imap0 (i: p: lib.nameValuePair (key p) i) l);
    in lib.concatLists (lib.imap0 (i: p: lib.optional (first.${key p} == i) p) l);
  # derivations named in the string context of plain strings (fhsBins, rpmBin)
  ctxDrvs = ss: lib.listToAttrs (lib.concatMap (s:
    lib.mapAttrsToList (k: _: lib.nameValuePair k "context")
      (lib.filterAttrs (_: c: c ? outputs) (builtins.getContext s))) ss);
  drvsOf = l: lib.filter lib.isDerivation l;
  # every SRPM a package of the stage is built from (variants included)
  srpms = lib.unique (packages ++ lib.attrValues variants);

  self = assert lib.assertMsg (!buildPure || fhsAllowlist == { })
    "stage ${name}: fhsAllowlist is a bootstrap-only exception (design §1.4.3), not allowed with buildPure"; {
    inherit name stdenv buildPure fhsPath defines rpmBin rpmLibDir rpmConfig toolShim patchelf
      python3 bsdtar fhsBins ccFor libcFor libcSrpm exceptionsFor purity fallback packages prev
      fhsAllowlist linkOutputs uniqPaths variants rpmConfigWith lateBindFor lateBindPkgs interpreterPkgs;
    stdenvNoCC = stdenv;
    rpmPkg = rpm;   # the rpm package (`rpm` is the RPM-name alias set)
    baseTools = baseTools ++ [ python3 bsdtar ];

    runtimeLibcFor = srpm: if srpm == libcSrpm then null else (libcFor srpm).out;
    libcDevFor = srpm: (libcFor srpm).dev;
    systemLibDirsFor = srpm:
      if srpm == libcSrpm then [ "@out@/lib64" "@out@/lib" ] else systemLibDirs srpm;

    overridesFor = overridesFor { stage = self; };

    pkgs = lib.genAttrs packages (srpm: mkRpmPackage self { inherit srpm; })
      // lib.mapAttrs (attr: srpm: mkRpmPackage self { inherit srpm; pname = attr; }) variants
      // extraPkgs self;

    # the subpackages a variant builds (its override's builtSubpackages, else
    # the lock's); reading the override file forces no package evaluation
    variantBuilt = attr:
      let b = (self.overridesFor attr).builtSubpackages; in
      if b != null then b else (subpackages.${variants.${attr}} or { names = [ ]; }).names;

    # shipped RPM name -> output of the stage package (keys from the lock and
    # the variants' override files only, so listing them forces no package
    # evaluation); a package of `packages` wins over a variant of its SRPM
    # (listToAttrs keeps the first occurrence of a name: packages first)
    rpm = lib.listToAttrs (lib.concatMap (srpm:
      let s = subpackages.${srpm} or { names = [ ]; shipped = { }; }; in
      map (n: lib.nameValuePair n (let p = self.pkgs.${srpm}; in p.${p.rpmOutputs.${n}}))
        (lib.filter (n: s.shipped.${n} or false) s.names)) packages
      ++ lib.concatMap (attr:
      let s = subpackages.${variants.${attr}} or { names = [ ]; shipped = { }; }; in
      map (n: lib.nameValuePair n (let p = self.pkgs.${attr}; in p.${p.rpmOutputs.${n}}))
        (lib.filter (n: s.shipped.${n} or false) (self.variantBuilt attr))) (lib.attrNames variants));

    # rpm name -> the variant building it (only for SRPMs not in `packages`)
    variantOf = lib.listToAttrs (lib.concatMap (attr:
      lib.optionals (!(lib.elem variants.${attr} packages))
        (map (n: lib.nameValuePair n attr) (self.variantBuilt attr))) (lib.attrNames variants));

    resolveBuildDeps = srpm: inputs:
      let
        b = builddeps.srpms.${srpm} or { inputs = [ ]; };
        wanted = lib.subtractLists inputs.drop (lib.unique ((b.inputs or [ ]) ++ inputs.buildRequires or [ ]));
        providerOf = r: builddeps.providers.${r} or { srpm = null; tags = [ "other" ]; };
        inStage = r: let p = providerOf r; in
          p.srpm != null && (lib.elem p.srpm packages || self.variantOf ? ${r})
          && p.srpm != srpm && usesStagePackage srpm p.srpm;
        fromStage = lib.filter inStage wanted;
        rest = lib.filter (r: !(inStage r)) wanted;
        unmapped = lib.filter (r: !(fallback ? ${r})) rest;
        # BuildRequires without a provider in the lock: named or an error
        unresolved = b.unresolved or [ ];
        unresolvedUnnamed = lib.filter (r: !(lib.elem r inputs.drop) && !(fallback ? ${r})) unresolved;
        fbs = map (r: fallback.${r}) (lib.filter (r: fallback ? ${r} && !(fallback.${r} ? drop)) rest);
        dropped = lib.filter (r: fallback ? ${r} && fallback.${r} ? drop) rest;

        stageOut = r:
          let s = self.variantOf.${r} or (providerOf r).srpm; p = self.pkgs.${s}; in
          if p.rpmOutputs ? ${r} then p.${p.rpmOutputs.${r}}
          else throw "stage ${name}: ${srpm}: BuildRequires provider ${r} is not a subpackage of ${s} (rpmOutputs: ${toString (lib.attrNames p.rpmOutputs)})";
        tagged = t: lib.filter (r: lib.elem t (providerOf r).tags) fromStage;
        libsR = tagged "lib";
        macroR = tagged "macro";
        toolR = lib.filter (r: !(lib.elem r libsR) && !(lib.elem r macroR)) fromStage;

        isRocky = d: d ? rockyRequisites;
        # the Rocky outputs used: host providers and Rocky inputs.add, each
        # with its companions
        rockyHost = uniqPaths (lib.concatMap (r: linkOutputs (stageOut r)) libsR
          ++ lib.concatMap linkOutputs (lib.filter isRocky inputs.add));
        stageMacro = map stageOut macroR;
        stageNative = map stageOut toolR;
        addOther = lib.filter (d: !(isRocky d)) inputs.add ++ inputs.addBuildOnly or [ ];
      in
      if unmapped != [ ] then
        throw ("stage ${name}: ${srpm}: BuildRequires providers neither built by the stage nor in its fallback set: "
          + lib.concatMapStringsSep ", " (r: "${r} (SRPM ${toString (providerOf r).srpm})") unmapped
          + "; add them to the stage's `packages`, its `fallback`, or the package's inputs.drop")
      else if unresolvedUnnamed != [ ] then
        throw ("stage ${name}: ${srpm}: BuildRequires the lock could not resolve (builddeps.json unresolved): "
          + lib.concatStringsSep ", " unresolvedUnnamed
          + "; name each in the package's inputs.drop (with the reason in a comment) or in the stage's `fallback`")
      else {
        native = stageNative ++ stageMacro ++ lib.concatMap (f: f.native or [ ]) fbs ++ inputs.addNative;
        host = rockyHost ++ addOther ++ lib.concatMap (f: f.host or [ ]) fbs;
        # libraries/headers reachable through /usr (and the $out alias): host
        # inputs only (every one is also a cc-wrapper input)
        view = rockyHost ++ addOther ++ lib.concatMap (f: f.view or [ ]) fbs;
        macro = stageMacro;
        macroDirs = lib.concatMap (f: f.macroDirs or [ ]) fbs;
        macroPkgs = uniqPaths (lib.concatMap (f: f.macroPkgs or [ ]) fbs);
        # the runtime-input outputs actually used (§7.1): what the outputs may
        # reference directly; their rockyRequisites bound the closure
        runtime = rockyHost;
        buildOnly = addOther;
        inherit dropped fromStage unresolved;
        fromFallback = lib.filter (r: fallback ? ${r} && !(fallback.${r} ? drop)) rest;
      };

    # the derivations a build in this stage may depend on (§7.3): the stage's
    # packages, the previous stage's, the builder machinery (tools, shim,
    # rpm + its config, every package's libc) and the derivations behind the
    # FHS strings (rpmBin, rpmLibDir, fhsBins).  The ccFor wrappers are
    # transparent (built from nixpkgs wrapper sources around stage tools: the
    # check descends into them), as is the stdenv; fallback entries are NOT
    # allowed (a buildPure stage has no fallback tools)
    libcs = lib.concatMap (s: let l = libcFor s; in drvsOf [ (l.out or null) (l.dev or null) ]) srpms;
    allowedBuildDrvs = purity.drvSet (lib.attrValues self.pkgs ++ self.baseTools
        ++ drvsOf [ toolShim patchelf rpm rpmConfig ] ++ self.libcs
        ++ lib.optionals (prev != null) (lib.attrValues prev.pkgs))
      // ctxDrvs (fhsBins ++ [ rpmBin rpmLibDir ]);
    transparent = uniqPaths (drvsOf (map ccFor srpms)) ++ transparent;
    extraAllowedSources = [ "${partitionTool}" ] ++ extraAllowedSources;
    purityChecker = purity.forStage self;
  } // extra self;
in
self
