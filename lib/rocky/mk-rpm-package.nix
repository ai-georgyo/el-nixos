# mkRpmPackage (docs/nix-native-design.md §11.1): one plain multi-output
# derivation per SRPM.  rpmbuild (the spec engine) compiles with %_prefix =
# $out inside the tool shim; rocky-partition then moves the BUILDROOT into
# one Nix output per subpackage.
#
#   mkRpmPackage stage { srpm, overrides ? <packages/<srpm>/default.nix> }
#
# `stage` is a mkStage fixpoint (lib/rocky/stage.nix); this file reads
#   name stdenv ccFor baseTools fhsBins rpmBin rpmLibDir rpmConfig toolShim
#   patchelf runtimeLibcFor libcDevFor systemLibDirsFor exceptionsFor
#   resolveBuildDeps fhsPath overridesFor purity (and purityChecker through it)
#
# Runtime vs build-only inputs: what an output may reference is its siblings,
# the stage libc (runtimeLibcFor), Rocky-built host inputs (passthru
# rockyRequisites, transitively) and stage.exceptionsFor srpm; that list is
# both outputChecks.<o>.allowedRequisites and the partition plan's
# allowedStorePaths, and its lib dirs are the plan's inputLibDirs.  Every
# other input (nixpkgs/stage0 tools, hoisted stage0 trees) is build-only.
# The view (/usr and the $out alias) holds host inputs + the libc's dev
# only: tools are PATH-only, so no library is reachable through the view
# without also being a cc-wrapper input (E2 library hazard).
#
# The derivation (all §11.1 items; the experiments' corrections applied):
#   outputs       names.outputsFor (out first, sorted, debug, logs)
#   unpack        bsdtar of the locked SRPM into rpmbuild/SOURCES (+ exact-count
#                 specSubstitutions on the copy in rpmbuild/SPECS)
#   rpm config    <stage.rpmConfig>/nix/instantiate per build: @PREFIX@ = $out,
#                 %distcore = lib/srpm.nix distOf (never %dist, lock.md),
#                 appended to redhat/macros (never macros.d, E2/rpmconfig.md);
#                 macro inputs via NIX_RPM_MACRO_DIRS
#   CONFIG_SITE   lib/rocky/config.site + the package fragment
#   prep          NIX_PREP_PATCHES (nixPatches) / NIX_PREP_SCRIPT (prepScript),
#                 run by %__spec_prep_post
#   rpmbuild      ${toolShim} -- env -u SOURCE_DATE_EPOCH [PATH=/usr/bin]
#                 ['k=v' ...] rpmbuild -bb --nodeps --noclean [--nocheck]
#                 --target x86_64 ...   (rockyViewInputs = declared inputs,
#                 RPM_CONFIG_DIR, ROCKY_PREFIX_VIEW = prefixView; the cc
#                 wrapper is first on PATH; NIX_ROCKY_MAP_ROOTS from the
#                 wrapper's setup hook plus $out while the alias exists)
#   partition     python3 -I ${partitionTool}/rocky-partition --plan <plan.json>
#                 (rockyPlan from the structured attrs + buildroot/rpmsDir found
#                 at build time)
#   fixup         patchShebangs --host only (strictDeps: HOST_PATH = runtime
#                 inputs); strip, patchELF, moveLib64, moveSbin, move-docs,
#                 gzipMan, prune-libtool-files, symlink rewriting, the
#                 broken-symlink check and the multiple-outputs.sh hooks off
#   enforcement   outputChecks.<o>.allowedRequisites (§7.1): siblings minus
#                 debug/logs + runtime inputs' rockyRequisites + stage
#                 exceptions; debug may reference siblings; logs nothing
#   logs          build.log (store hashes normalised), rocky-report.json,
#                 view collisions
#
# Override `env` keys that are not shell identifiers (glibc's
# user-defined-trusted-dirs) never enter the structured `env` (setup.sh's
# `declare -x` aborts on them, E5): they are passed as `env 'k=v' rpmbuild`.
{ lib, names, overridesLib, unions, partitionTool, srpmLib, lock }:
stage:
{ srpm
, overrides ? stage.overridesFor srpm
}:
let
  e = srpmLib.entry srpm;
  sub = names.subpackagesFor srpm;
  ov = overridesLib.checkOutputs "packages/${srpm}/default.nix" overrides outs;
  outs = names.outputsFor {
    inherit srpm sub;
    inherit (overrides) mergeOutputs prefixSubpackage;
  };
  hasDebug = lib.elem "debug" outs.outputs;
  managed = lib.filter (o: o != "debug" && o != "logs") outs.outputs;

  deps = stage.resolveBuildDeps srpm ov.inputs;
  cc = stage.ccFor srpm;
  # the libc programs of this package run against (null for the libc itself,
  # whose programs find it in their own system dir)
  libc = stage.runtimeLibcFor srpm;

  # ---- runtime closure (inductive, §7.1) ----------------------------------
  # runtime inputs: the stage libc and Rocky-built host inputs (mkRpmPackage
  # results carry passthru.rockyRequisites / rockyOutputs); plus the named
  # stage exceptions.  Everything else (nixpkgs/stage0 tools, hoisted stage0
  # trees, glibcBuildDeps) is build-only: not allowed in any output.
  runtimeInputs = lib.optional (libc != null) libc ++ deps.runtime;
  requisitesOf = d: d.rockyRequisites or [ d ];
  runtimeClosure = lib.unique (stage.exceptionsFor srpm ++ lib.concatMap requisitesOf runtimeInputs);
  outputsOf = d: d.rockyOutputs or [ d ];
  libDirsOf = d: lib.concatMap (o: [ "${o}/lib64" "${o}/lib" ]) (outputsOf d);

  # ---- partition plan (tools/rocky-partition/PLAN.md, schema v1) -----------
  isIdent = k: builtins.match "[A-Za-z_][A-Za-z0-9_]*" k != null;
  identEnv = lib.filterAttrs (k: _: isIdent k) ov.env;
  cmdEnv = lib.filterAttrs (k: _: !(isIdent k)) ov.env;

  # opaqueRefs: "<output>" / "<output>:<rel glob>" (PLAN.md); the draft form
  # "<output>/<rel>" of packages/glibc/default.nix is accepted and converted
  # when its first component is an output of this package
  opaqueRef = r:
    let parts = lib.splitString "/" r; o = lib.head parts; in
    if lib.hasInfix ":" r || lib.length parts < 2 || !(lib.elem o outs.outputs) then r
    else "${o}:${lib.concatStringsSep "/" (lib.tail parts)}";

  # generic build-time search paths for the generated setup hooks: the list
  # variables of lib/rocky/unions.nix without provider/yieldsTo (the
  # partitioner writes plain addToSearchPath lines), minus XDG_DATA_DIRS
  # (every output with share/ would get one)
  searchPaths = lib.foldl' (acc: v:
    let t = unions.table.${v}; in
    if t.kind == "list" && t.provider == null && t.yieldsTo == [ ] && lib.elem "build" t.when
       && v != "XDG_DATA_DIRS"
    then acc // lib.genAttrs t.dirs (_: v) else acc) { } unions.vars;

  rockyPlan = {
    version = 1;
    inherit srpm;
    rpm = stage.rpmBin;
    rpmConfigDir = stage.rpmLibDir;
    prefixOutput = "out";
    subpackages = lib.filterAttrs (n: _: !(names.isDebugName n)) outs.rpmOutputs;
    debugOutput = if hasDebug then "debug" else null;
    unmanagedOutputs = [ "logs" ];
    inherit (ov) mergeOutputs layout runtimeSearchPaths unionDirs danglingOk lateReferrers
      noPatchelf fhsAllowlist strictFhs allowUnresolvedNeeded prefixRelativeOk integrityOk;
    inherit searchPaths;
    opaqueRefs = map opaqueRef ov.opaqueRefs;
    forward = ov.forward;
    lateBind = ov.lateBind;
    systemLibDirs = if ov.systemLibDirs != null then ov.systemLibDirs else stage.systemLibDirsFor srpm;
    inputLibDirs = lib.unique (lib.concatMap libDirsOf runtimeInputs);
    allowedStorePaths = map toString runtimeClosure;
    patchelf = "${stage.patchelf}/bin/patchelf";
    maxSamples = 50;
  };

  # ---- rpmbuild arguments ----------------------------------------------------
  # layout (§2.7): compile a directory macro as another output's path
  # (`{ _datadir = "common"; }` -> --define "_datadir <$common>/share"); the
  # partitioner maps header paths below any output
  layoutRel = {
    _bindir = "bin"; _sbindir = "sbin"; _libdir = "lib64"; _libexecdir = "libexec";
    _datadir = "share"; _includedir = "include"; _infodir = "share/info";
    _mandir = "share/man"; _docdir = "share/doc"; _defaultdocdir = "share/doc";
    _datarootdir = "share"; _localedir = "share/locale";
  };
  layoutArgs = lib.concatLists (lib.mapAttrsToList (m: o:
    if layoutRel ? ${m} then [ "--define" "${m} ${builtins.placeholder o}/${layoutRel.${m}}" ]
    else throw "mkRpmPackage ${srpm}: layout.${m}: no standard directory known for this macro (lib/rocky/mk-rpm-package.nix layoutRel)")
    ov.layout);
  defineArgs = lib.concatLists (lib.mapAttrsToList (k: v: [ "--define" "${k} ${toString v}" ]) ov.defines)
    ++ layoutArgs;
  bcondArgs = lib.concatMap (w: [ "--with" w ]) ov.bconds."with"
    ++ lib.concatMap (w: [ "--without" w ]) ov.bconds.without;
  substitutions = map (s: { inherit (s) from to count; }) ov.specSubstitutions;

  configSites = [ "${stage.rpmConfig.configSite}" ]
    ++ lib.optional (ov.configSite != null) "${ov.configSite}";

  macroDirs = lib.concatMap (m: [ "${m}/lib/rpm/macros.d" ]) deps.macro ++ deps.macroDirs;

  name = names.storeName { inherit srpm; inherit (e) version release; };

  raw = stage.stdenv.mkDerivation {
    inherit name;
    outputs = outs.outputs;
    __structuredAttrs = true;
    strictDeps = true;
    src = srpmLib.fetchSrpm srpm;

    # cc first: its bin/ heads PATH and wins in the view's /usr/bin
    nativeBuildInputs = [ cc ] ++ deps.native ++ stage.baseTools;
    buildInputs = deps.host;

    # declared inputs (+ the libc's dev, last: Rocky's buildroot has
    # glibc-devel in /usr/include) -- only libraries/headers that are also
    # cc-wrapper inputs, so no library is reachable through the view alone
    # (E2 library hazard); tools are PATH-only
    rockyViewInputs = map toString (lib.unique (deps.view ++ [ (stage.libcDevFor srpm) ]));
    rockyFhsBins = stage.fhsBins;
    rockyRpmConfig = "${stage.rpmConfig}";
    rockyDist = srpmLib.distOf srpm;
    rockyRpmbuildArgs = defineArgs ++ bcondArgs;
    rockyRpmbuildEnv = lib.mapAttrs (_: toString) cmdEnv;
    rockySubstitutions = substitutions;
    rockyNixPatches = map (p: "${p}") ov.nixPatches;   # "${}": paths copied with context
    rockyPrepScript = ov.prepScript;
    rockyConfigSite = lib.concatStringsSep " " configSites;
    rockyMacroDirs = macroDirs;
    rockyDoCheck = ov.doCheck;
    rockyPrefixView = ov.prefixView;
    rockyFhsPath = stage.fhsPath;
    rockyPartition = "${partitionTool}/rocky-partition";
    inherit rockyPlan;

    env = {
      NIX_HARDENING_ENABLE = "";
      # brp check-rpaths: every store RUNPATH is "invalid" (0x0002) to it
      # (E2/E3 finding; design §5.5 corrected)
      QA_RPATHS = "0x0002";
    } // lib.mapAttrs (_: v: if v == null then "" else toString v) identEnv;

    # §5.3 fixup settings (rocky-partition did the moving; rpm stripped)
    dontStrip = true;
    dontPatchELF = true;
    dontMoveLib64 = true;
    dontMoveSbin = true;
    dontMoveSystemdUserUnits = true;
    dontGzipMan = true;
    dontPruneLibtoolFiles = true;
    dontRewriteSymlinks = true;
    dontCheckForBrokenSymlinks = true;   # danglingOk links are the partitioner's call
    # multiple-outputs.sh: no flags, no moving, no dev propagation (names-fix.md)
    setOutputFlags = false;
    moveToDev = false;
    propagatedBuildOutputs = "";
    dontPatch = true;

    unpackPhase = ''
      runHook preUnpack
      top=$NIX_BUILD_TOP/rpmbuild
      mkdir -p $top/SOURCES $top/SPECS
      bsdtar -xf "$src" -C $top/SOURCES
      chmod -R u+w $top/SOURCES
      spec=$top/SOURCES/${srpm}.spec
      [ -f "$spec" ] || { echo "mkRpmPackage: ${srpm}.spec not in the SRPM" >&2; exit 1; }
      cp "$spec" $top/SPECS/${srpm}.spec
      # specSubstitutions: each `from` must occur exactly `count` times
      python3 -I - "$NIX_ATTRS_JSON_FILE" $top/SPECS/${srpm}.spec <<'EOF'
      import json, sys
      subs = json.load(open(sys.argv[1]))["rockySubstitutions"]
      p = sys.argv[2]
      s = open(p).read()
      for x in subs:
          n = s.count(x["from"])
          if n != x["count"]:
              sys.exit("specSubstitution %r: %d occurrences, want %d" % (x["from"], n, x["count"]))
          s = s.replace(x["from"], x["to"])
          print("specSubstitution: %r -> %r (%d)" % (x["from"], x["to"], n))
      open(p, "w").write(s)
      EOF
      cd $NIX_BUILD_TOP
      runHook postUnpack
    '';

    configurePhase = ''
      runHook preConfigure
      export NIX_RPM_MACRO_DIRS="''${rockyMacroDirs[*]}"
      sh $rockyRpmConfig/nix/instantiate $NIX_BUILD_TOP/rpmconfig --prefix "$out" \
        --buildtop $NIX_BUILD_TOP --ncpus "''${NIX_BUILD_CORES:-1}" --dist "$rockyDist"
      export RPM_CONFIG_DIR=$NIX_BUILD_TOP/rpmconfig
      export CONFIG_SITE="$rockyConfigSite"
      export NIX_PREP_PATCHES="''${rockyNixPatches[*]}"
      if [ -n "$rockyPrepScript" ]; then
        printf '%s\n' "$rockyPrepScript" > $NIX_BUILD_TOP/prep-script.sh
        export NIX_PREP_SCRIPT=$NIX_BUILD_TOP/prep-script.sh
      fi
      # FHS-installed tools (the stage0 rpm, debugedit): PATH after the cc
      for d in ''${rockyFhsBins[@]}; do PATH="$PATH:$d"; done
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      top=$NIX_BUILD_TOP/rpmbuild
      rpmArgs=(-bb --nodeps --noclean --target x86_64)
      [ -n "$rockyDoCheck" ] || rpmArgs+=(--nocheck)
      rpmArgs+=("''${rockyRpmbuildArgs[@]}")
      # env names that are not shell identifiers (make variables): command line only
      envArgs=(-u SOURCE_DATE_EPOCH)
      # fhsPath: tools by their /usr/bin names, and the shell environment of a
      # mock chroot (SHELL=/bin/bash, no CONFIG_SHELL): stdenv exports
      # CONFIG_SHELL=<nixpkgs bash>, which autoconf writes into every
      # `#! @SHELL@` script (gzip's z*, xz's xz*grep: Rocky has #!/usr/bin/sh)
      [ -z "$rockyFhsPath" ] || envArgs+=(-u CONFIG_SHELL PATH=/usr/bin SHELL=/bin/bash)
      for k in "''${!rockyRpmbuildEnv[@]}"; do envArgs+=("$k=''${rockyRpmbuildEnv[$k]}"); done
      if [ -n "$rockyPrefixView" ]; then
        export ROCKY_PREFIX_VIEW=1
        # -ffile-prefix-map=$out=/usr while the view is aliased at $out
        # (E2: headers reached through %{_includedir} of the alias)
        export NIX_ROCKY_MAP_ROOTS="''${NIX_ROCKY_MAP_ROOTS:+$NIX_ROCKY_MAP_ROOTS }$out"
      else
        export ROCKY_PREFIX_VIEW=0
      fi
      echo "=== rpmbuild ''${rpmArgs[*]} ${srpm}.spec (prefix $out, stage ${stage.name})"
      set +e
      ROCKY_VIEW_COLLISIONS=$NIX_BUILD_TOP/view-collisions.txt \
        ${stage.toolShim} -- env "''${envArgs[@]}" rpmbuild "''${rpmArgs[@]}" $top/SPECS/${srpm}.spec \
        2>&1 | tee $NIX_BUILD_TOP/build.log
      rc=''${PIPESTATUS[0]}
      set -e
      if [ $rc -ne 0 ]; then echo "mkRpmPackage: rpmbuild failed ($rc)" >&2; exit $rc; fi
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      top=$NIX_BUILD_TOP/rpmbuild
      # rockyPlan + what only the build knows (the BUILDROOT's name)
      python3 -I - "$NIX_ATTRS_JSON_FILE" $top $NIX_BUILD_TOP/plan.json <<'EOF'
      import json, os, sys
      attrs = json.load(open(sys.argv[1]))
      top = sys.argv[2]
      plan = dict(attrs["rockyPlan"])
      roots = [os.path.join(top, "BUILDROOT", d) for d in sorted(os.listdir(os.path.join(top, "BUILDROOT")))]
      if len(roots) != 1:
          sys.exit("mkRpmPackage: expected one BUILDROOT, found %r" % roots)
      plan["buildroot"] = roots[0]
      plan["rpmsDir"] = os.path.join(top, "RPMS")
      plan["outputs"] = attrs["outputs"]
      plan["reportFile"] = os.path.join(os.path.dirname(sys.argv[3]), "rocky-report.json")
      json.dump(plan, open(sys.argv[3], "w"), indent=1, sort_keys=True)
      EOF
      set +e
      python3 -I $rockyPartition --plan $NIX_BUILD_TOP/plan.json
      rc=$?
      set -e
      mkdir -p $logs
      sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' \
        $NIX_BUILD_TOP/build.log > $logs/build.log
      for f in rocky-report.json view-collisions.txt plan.json; do
        if [ -f $NIX_BUILD_TOP/$f ]; then
          sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' \
            $NIX_BUILD_TOP/$f > $logs/$f
        fi
      done
      if [ $rc -ne 0 ]; then echo "mkRpmPackage: rocky-partition failed ($rc)" >&2; exit $rc; fi
      # §5.6: a -devel output propagates the sibling outputs its subpackage
      # Requires (unique provider, from the transient headers: the report's
      # outputRequires), as nixpkgs' dev propagates lib: `buildInputs = [ xz.dev ]`
      # then links and runs against xz.lib
      python3 -I - "$NIX_ATTRS_JSON_FILE" "$out/nix-support/rocky-report.json" <<'EOF'
      import json, os, sys
      attrs = json.load(open(sys.argv[1]))
      outs = attrs["outputs"]
      rep = json.load(open(sys.argv[2]))
      subs = attrs["rockyPlan"]["subpackages"]
      devel = sorted({o for n, o in subs.items() if n.endswith("-devel")})
      for o in devel:
          req = [x for x in rep.get("outputRequires", {}).get(o, []) if x in outs and x not in (o, "debug", "logs")]
          if not req:
              continue
          d = os.path.join(outs[o], "nix-support")
          os.makedirs(d, exist_ok=True)
          with open(os.path.join(d, "propagated-build-inputs"), "a") as f:
              f.write("".join(" " + outs[x] for x in sorted(req)))
          print("propagated-build-inputs: %s -> %s" % (o, " ".join(sorted(req))))
      EOF
      # the moving/propagating hooks of nixpkgs' multiple-outputs.sh and
      # move-docs.sh would undo the partition (they run in fixupPhase)
      preFixupHooks=($(for h in "''${preFixupHooks[@]}"; do
        case $h in _multioutDocs|_multioutDevs|_moveToShare) ;; *) echo "$h" ;; esac; done))
      postFixupHooks=($(for h in "''${postFixupHooks[@]}"; do
        case $h in _multioutPropagateDev) ;; *) echo "$h" ;; esac; done))
      runHook postInstall
    '';

    outputChecks =
      let
        siblings = lib.filter (o: o != "debug" && o != "logs") outs.outputs;
        allowed = siblings ++ runtimeClosure;
      in
      lib.genAttrs siblings (_: { allowedRequisites = allowed; })
      // lib.optionalAttrs hasDebug { debug.allowedRequisites = allowed ++ [ "debug" ]; }
      // { logs.allowedReferences = [ ]; };

    passthru = {
      rockyStage = stage.name;
      inherit srpm;
      inherit (outs) rpmOutputs shippedRpmOutputs unshipped;
      overrides = ov;
      # what a consumer's closure may contain because of this package (§7.1)
      rockyOutputs = map (o: raw.${o}) managed;
      rockyRequisites = lib.unique (map (o: raw.${o}) managed ++ runtimeClosure);
      rockyDeps = deps;
      inherit rockyPlan;
    };
  };
in
stage.purity.check stage raw
