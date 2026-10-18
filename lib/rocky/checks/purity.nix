# checks.nn-purity: positive and negative tests of the build-purity assertion
# (lib/rocky/purity.nix), and the E6 fixture
# (docs/research/nix-native/experiments/E6.md).
#
# All tests are pure evaluation; their results are baked into the env of a
# trivial derivation, which fails (printing the failing tests) if any test
# failed, so evaluation never breaks and the check "builds" instantly.
#
# E6: nixpkgs wrapCCWith/wrapBintoolsWith instantiated with a NON-nixpkgs
# stdenvNoCC -- a generic stdenv (import "${nixpkgsSrc}/pkgs/stdenv/generic")
# over stand-in tools: nixpkgs outputs re-exported by fresh derivations
# (`restage`), which the E6 stage lists in allowedBuildDrvs as if they were
# Rocky-built.  `naive` overrides only stdenvNoCC; `full` also overrides what
# the assertion flags.  passthru.e6 exposes the pieces for nix eval.
{ bootPkgs, lib, nixpkgsSrc, repo, fetch, stage0, self, ... }:
let
  purity = self.purity;
  inherit (purity) drvPathOf;
  system = "x86_64-linux";
  platform = bootPkgs.stdenv.hostPlatform;

  # a fresh derivation whose outputs are symlinks to nixpkgs outputs
  restage = name: outs: extra:
    builtins.derivation {
      name = "e6-${name}";
      inherit system;
      outputs = [ "out" ] ++ lib.remove "out" (attrNames outs); # first = default output
      builder = "${bootPkgs.bash}/bin/bash";
      args = [ "-c" (lib.concatStrings (lib.mapAttrsToList (o: p: "${bootPkgs.coreutils}/bin/ln -s ${p} \$${o}\n") outs)) ];
    } // extra;
  inherit (builtins) attrNames;

  tools = {
    coreutils = restage "coreutils-${bootPkgs.coreutils.version}" { out = bootPkgs.coreutils; } { };
    findutils = restage "findutils" { out = bootPkgs.findutils; } { };
    diffutils = restage "diffutils" { out = bootPkgs.diffutils; } { };
    gnused = restage "gnused" { out = bootPkgs.gnused; } { };
    gnugrep = restage "gnugrep" { out = bootPkgs.gnugrep; } { };
    gawk = restage "gawk" { out = bootPkgs.gawk; } { };
    gnutar = restage "gnutar" { out = bootPkgs.gnutar; } { };
    gzip = restage "gzip" { out = bootPkgs.gzip; } { };
    bzip2 = restage "bzip2" { out = bootPkgs.bzip2.bin; } { };
    gnumake = restage "gnumake" { out = bootPkgs.gnumake; } { };
    bash = restage "bash" { out = bootPkgs.bashNonInteractive; } { shellPath = "/bin/bash"; };
    patch = restage "patch" { out = bootPkgs.patch; } { };
    xz = restage "xz" { out = bootPkgs.xz.bin; } { };
    file = restage "file" { out = bootPkgs.file; } { };
    gcc = restage "gcc-${bootPkgs.stdenv.cc.cc.version}" { out = bootPkgs.stdenv.cc.cc; lib = bootPkgs.stdenv.cc.cc.lib; }
      { isGNU = true; langC = true; langCC = true; };
    binutils = restage "binutils-${bootPkgs.binutils-unwrapped.version}" { out = bootPkgs.binutils-unwrapped; }
      { isGNU = true; };
    glibc = restage "glibc-${bootPkgs.glibc.version}" { out = bootPkgs.glibc.out; dev = bootPkgs.glibc.dev; bin = bootPkgs.glibc.bin; } { };
    expand-response-params = restage "expand-response-params" { out = bootPkgs.expand-response-params; }
      { meta.mainProgram = "expand-response-params"; };
  };

  genericStdenv = { name, cc, initialPath ? with tools; [ coreutils findutils diffutils gnused gnugrep gawk gnutar gzip bzip2 gnumake bash patch xz file ] }:
    import (nixpkgsSrc + "/pkgs/stdenv/generic") {
      inherit name cc initialPath;
      inherit (bootPkgs) config;
      buildPlatform = platform;
      hostPlatform = platform;
      targetPlatform = platform;
      shell = "${tools.bash}/bin/bash";
      fetchurlBoot = throw "E6 stdenv: no fetchurlBoot";
    };

  stdenvNoCC = genericStdenv { name = "e6-stdenv-nocc"; cc = null; };

  # nixpkgs wrappers; `over` = the arguments replacing nixpkgs defaults
  wrappers = over: rec {
    bintools = bootPkgs.wrapBintoolsWith ({ bintools = tools.binutils; libc = tools.glibc; inherit stdenvNoCC; } // over);
    cc = bootPkgs.wrapCCWith ({ cc = tools.gcc; inherit bintools; libc = tools.glibc; inherit stdenvNoCC; isGNU = true; } // over);
    stdenv = genericStdenv { name = "e6-stdenv"; inherit cc; };
  };
  naive = wrappers { };
  full = wrappers {
    runtimeShell = "${tools.bash}/bin/bash";
    inherit (tools) coreutils gnugrep expand-response-params;
  };

  mkStage = w: name: {
    inherit name;
    buildPure = true;
    allowedBuildDrvs = purity.drvSet (lib.attrValues tools);
    inherit (w) stdenv;
    inherit stdenvNoCC;
  };
  stages = { naive = mkStage naive "e6-naive"; full = mkStage full "e6-full"; };

  hello = w: w.stdenv.mkDerivation {
    name = "e6-hello";
    dontUnpack = true;
    buildPhase = ''
      cat > hello.c <<'EOF'
      #include <stdio.h>
      int main(void) { puts("hello from the E6 stdenv"); return 0; }
      EOF
      gcc -O2 hello.c -o hello
      ./hello
    '';
    installPhase = "mkdir -p $out/bin && cp hello $out/bin/";
  };

  # n trivial packages of the E6 stage, for the eval-cost measurement:
  #   nix eval --raw .#checks.x86_64-linux.nn-purity.e6.scale --apply 'f: f "shared" 2200'
  # mode: plain (no check), check (memo per package), shared (stage.purityChecker)
  scale = mode: n:
    let
      st = if mode == "shared" then S // { purityChecker = purity.forStage S; } else S;
      pkg = i: full.stdenv.mkDerivation {
        name = "e6-scale-${toString i}";
        src = fetch.fetchSrpm "which";
        nativeBuildInputs = [ tools.file tools.xz ];
        buildPhase = "echo ${toString i}";
        installPhase = "touch $out";
      };
      wrap = if mode == "plain" then (d: d) else purity.check st;
    in
    builtins.deepSeq (builtins.genList (i: (wrap (pkg i)).drvPath) n) "${mode} ${toString n} ok";

  # one package with n extra outputs and 2000 context strings, every output's
  # drvPath read (as hydraJobs.rpms would): the check must walk it once
  #   nix eval --raw .#checks.x86_64-linux.nn-purity.e6.outputsCost --apply 'f: f "check" 200'
  outputsCost = mode: n:
    let
      d = full.stdenv.mkDerivation {
        name = "e6-multi";
        outputs = [ "out" ] ++ builtins.genList (i: "o${toString i}") n;
        dontUnpack = true;
        installPhase = "touch $out";
        x = builtins.genList (i: "${tools.file}/${toString i}") 2000;
      };
      c = if mode == "plain" then d else purity.check (S // { purityChecker = purity.forStage S; }) d;
    in
    builtins.deepSeq (map (o: c.${o}.drvPath) c.outputs) "${mode} ${toString n} ok";

  e6 = {
    inherit tools stdenvNoCC naive full stages scale outputsCost;
    hello = { naive = hello naive; full = hello full; };
    # as mkRpmPackage would expose them: nix build fails on `naive` with the report
    checked = { naive = purity.check stages.naive (hello naive); full = purity.check S (hello full); };
    violations = { naive = purity.violations stages.naive (hello naive); full = purity.violations S (hello full); };
    report = { naive = purity.report stages.naive (hello naive); full = purity.report S (hello full); };
  };

  # ---------------------------------------------------------------- tests
  S = stages.full;
  V = purity.violations S;
  pkg = attrs: full.stdenv.mkDerivation ({ name = "t"; dontUnpack = true; installPhase = "touch $out"; } // attrs);
  keys = vs: lib.sort lib.lessThan (lib.unique (map (v: v.key) vs));
  only = kind: key: chain: vs: vs == [ { inherit kind key chain; } ];
  flagged = d: vs: keys vs == [ (drvPathOf d) ];
  throws = x: !(builtins.tryEval (builtins.seq x true)).success;
  hello' = bootPkgs.hello;
  outside = nixpkgsSrc + "/pkgs/build-support/trivial-builders/default.nix";
  hook = nixpkgsSrc + "/pkgs/build-support/setup-hooks/move-lib64.sh";
  bad = pkg { nativeBuildInputs = [ hello' ]; };
  badMulti = pkg { outputs = [ "out" "dev" ]; nativeBuildInputs = [ hello' ]; installPhase = "touch $out $dev"; };
  shared = S // { purityChecker = purity.forStage S; };
  # design §11.3 lateBind shape: an output replaced by another derivation's
  bound = restage "glibc-bound" { out = bootPkgs.glibc.out; dev = bootPkgs.glibc.dev; } { };
  lateBound = tools.glibc // { dev = bound.dev; };
  withLate = S // { allowedBuildDrvs = S.allowedBuildDrvs // purity.drvSet [ lateBound ]; };
  raw = attrs: builtins.derivation ({ name = "raw"; inherit system; builder = "${tools.bash}/bin/bash"; } // attrs);
  # filtered / renamed repo copies: new store paths, need extraAllowedSources
  repoCopies = {
    path = builtins.path { path = repo + "/lib/rocky"; name = "rocky-src"; };
    fileset = lib.fileset.toSource { root = repo + "/lib/rocky"; fileset = repo + "/lib/rocky/purity.nix"; };
    clean = lib.cleanSource (repo + "/tools");
  };

  tests = {
    # E6: nixpkgs wrappers over a non-nixpkgs stdenvNoCC
    e6-full-pure = e6.violations.full == [ ];
    e6-naive-exact = keys e6.violations.naive
      == keys (map (d: { key = drvPathOf d; }) (with bootPkgs; [ coreutils bashNonInteractive gnugrep expand-response-params ]));
    e6-naive-throws = throws (purity.assertBuildPure stages.naive (hello naive));
    e6-naive-message = lib.all (s: lib.hasInfix s e6.report.naive) [
      "e6-hello is not build-pure for stage e6-naive" "derivation expand-response-params (/nix/store/"
      "via e6-hello.stdenv > e6-stdenv.defaultNativeBuildInputs[14] > e6-gcc-wrapper-${bootPkgs.stdenv.cc.cc.version}.expandResponseParams"
    ];
    e6-memo-seeds = lib.length (purity.forStage S).memoKeys == 4; # stdenv, stdenvNoCC, cc, bintools
    # derivations
    nixpkgs-input = only "derivation" (drvPathOf hello') ".nativeBuildInputs[0]" (V bad);
    nixpkgs-in-string = only "derivation" (drvPathOf hello') ".buildPhase" (V (pkg { buildPhase = "${hello'}/bin/hello"; }));
    nixpkgs-drvpath-string = flagged hello' (V (pkg { x = hello'.drvPath; }));
    # a drvPath string (allOutputs) exposes the build closure even of an allowed drv
    allowed-drvpath-string = only "drv-closure" (drvPathOf tools.coreutils) ".x" (V (pkg { x = tools.coreutils.drvPath; }));
    allowed-drv-file = only "drv-file" (drvPathOf tools.coreutils) ".x"
      (V (pkg { x = builtins.unsafeDiscardOutputDependency tools.coreutils.drvPath; }));
    # seeds are descended into even when listed in allowedBuildDrvs (S3a reusing S2's wrapper)
    allowed-seeds-descended = keys (purity.violations (stages.naive // {
      allowedBuildDrvs = stages.naive.allowedBuildDrvs // purity.drvSet [ naive.stdenv naive.cc naive.bintools stdenvNoCC ];
    }) (hello naive)) == keys e6.violations.naive;
    fake-drv-multi-context = flagged hello'
      (V (pkg { nativeBuildInputs = [ { type = "derivation"; name = "fake"; outPath = "${tools.bash}${hello'}"; } ]; }));
    fake-drv-source = only "source" "${outside}" ".x.outPath"
      (V (pkg { x = { type = "derivation"; name = "fake"; outPath = "${outside}"; }; }));
    drvset-latebind = purity.violations withLate (pkg { buildInputs = [ lateBound.dev lateBound.out ]; }) == [ ]
      && flagged bound (V (pkg { buildInputs = [ lateBound.dev ]; }));
    nixpkgs-stdenv = lib.any (v: lib.hasPrefix ".stdenv > stdenv-linux.initialPath[" v.chain)
      (V (bootPkgs.stdenv.mkDerivation { name = "t"; dontUnpack = true; installPhase = "touch $out"; }));
    stage0-drv = flagged stage0.rpm (V (pkg { nativeBuildInputs = [ stage0.rpm ]; }));
    official-rpm-fod = flagged (fetch.fetchRpm "glibc.x86_64") (V (pkg { rpm = fetch.fetchRpm "glibc.x86_64"; }));
    foreign-fod = keys (V (pkg { src = bootPkgs.fetchurl { url = "https://example.invalid/x"; hash = lib.fakeHash; }; })) != [ ];
    lock-fod-value = V (pkg { src = fetch.fetchSrpm "which"; }) == [ ];
    lock-fod-string = V (pkg { unpackPhase = "echo ${fetch.fetchSrpm "which"}"; }) == [ ];
    lock-fods-off = flagged (fetch.fetchSrpm "which") (purity.violations (S // { allowLockFods = false; }) (pkg { src = fetch.fetchSrpm "which"; }));
    # mkDerivation strips the context of these (no input); a raw derivation realises it
    disallowed-mkderivation = V (pkg { disallowedRequisites = [ hello' ]; disallowedReferences = [ hello' ]; }) == [ ];
    disallowed-raw = only "derivation" (drvPathOf hello') ".disallowedRequisites[0]" (V (raw { disallowedRequisites = [ hello' ]; }));
    ignore-attrs = purity.violations (S // { purityIgnoreAttrs = [ "disallowedRequisites" ]; })
      (raw { disallowedRequisites = [ hello' ]; }) == [ ];
    structured-attrs = # mkDerivation keeps `env` and also exports it at the top level
      let vs = V (pkg { __structuredAttrs = true; env.FOO = "${hello'}"; outputChecks.out.disallowedRequisites = [ hello' ]; });
      in flagged hello' vs && lib.elem ".env.FOO" (map (v: v.chain) vs);
    plain-attrs = only "derivation" (drvPathOf hello') ".nativeBuildInputs[0]" (V { nativeBuildInputs = [ hello' ]; });
    # sources
    nixpkgs-tree = # "${nixpkgsSrc}" = a store copy of the whole nixpkgs tree
      only "source" "${nixpkgsSrc}" ".x" (V (pkg { x = "${nixpkgsSrc}/pkgs/top-level/all-packages.nix"; }));
    nixpkgs-path-outside = only "path" (toString outside) ".x" (V (pkg { x = outside; }));
    nixpkgs-copy-outside = only "source" "${outside}" ".x" (V (pkg { x = "${outside}"; })); # same name as cc-wrapper/default.nix
    nixpkgs-hook-allowed = V (pkg { x = hook; y = "${hook}"; }) == [ ];
    repo-allowed = V (pkg { x = "${repo}/tools/rpm_purity.py"; y = "${repo + "/tools/rpm_purity.py"}"; z = repo + "/lib/chroot.sh"; }) == [ ];
    tofile-flagged = keys (V (pkg { x = "${builtins.toFile "x.sh" "true"}"; })) == [ "${builtins.toFile "x.sh" "true"}" ];
    extra-source = purity.violations (S // { extraAllowedSources = [ outside ]; }) (pkg { x = outside; y = "${outside}"; }) == [ ];
    repo-filtered-copies = lib.all (c: only "source" "${c}" ".x" (V (pkg { x = "${c}"; }))) (lib.attrValues repoCopies)
      && purity.violations (S // { extraAllowedSources = map (c: "${c}") (lib.attrValues repoCopies); })
        (pkg { x = map (c: "${c}") (lib.attrValues repoCopies); }) == [ ];
    # check / assertBuildPure
    assert-identity = (purity.assertBuildPure S (hello full)).drvPath == (hello full).drvPath;
    assert-throws = throws (purity.assertBuildPure S bad);
    check-noop = (purity.check (S // { buildPure = false; }) bad).drvPath == bad.drvPath;
    check-guards-drvpath = throws (purity.check S bad).drvPath;
    check-guards-output = throws (purity.check S badMulti).dev.drvPath;
    check-outpath-lazy = (builtins.tryEval (purity.check S bad).outPath).success;
    check-pure = (purity.check S (hello full)).drvPath == (hello full).drvPath;
    shared-checker = purity.violations shared bad == V bad && purity.violations shared (hello full) == [ ];
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) tests);
in
{
  nn-purity = bootPkgs.runCommand "nn-purity"
    {
      # booleans and context-free text only: the check depends on no test derivation
      results = lib.concatStringsSep "\n" (lib.mapAttrsToList (n: ok: "${if ok then "ok  " else "FAIL"} ${n}") tests);
      failed = toString failed;
      e6Report = builtins.unsafeDiscardStringContext e6.report.naive;
      passAsFile = [ "results" "e6Report" ];
      passthru = { inherit e6 tests; };
    } ''
    cat "$resultsPath"
    if [ -n "$failed" ]; then echo "nn-purity: failed: $failed" >&2; exit 1; fi
    mkdir -p $out
    cp "$resultsPath" $out/results.txt
    cp "$e6ReportPath" $out/e6-naive-report.txt
  '';
}
