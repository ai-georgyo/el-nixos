# Eval-time build-purity assertion (design §7.3, E6; docs/research/nix-native/experiments/E6.md).
#
# A derivation is build-pure for a stage when everything its builder can see
# comes from the stage:
#   * every derivation in the string context of its attributes is in
#     `stage.allowedBuildDrvs` (a set keyed by drvPath) or is a lock FOD
#     (fixed-output, hash of an SRPM in lock/rocky-<rel>/srpms.json);
#   * every plain source (path value, or `path` context entry) lies under
#     lib/rocky/allowed-sources.nix (+ `stage.extraAllowedSources`).
# The stage's stdenv, cc-wrapper and bintools-wrapper are not "allowed" by
# name: they are built from nixpkgs sources around stage tools, so they are
# *transparent* -- the check descends into their drvAttrs and applies the same
# rules there (that is how a nixpkgs expand-response-params, runtimeShell,
# coreutils or gnugrep inside a wrapper is found).  Transparent are the stage's
# stdenv, stdenvNoCC, stdenv.cc, stdenv.cc.bintools and `stage.transparent`
# (results memoised per drvPath), plus any derivation that looks like a
# nixpkgs stdenv or wrapper (at most 2 such levels deep, not memoised: that
# only happens on the way to an error).
#
# Pure evaluation: builtins.getContext over drvAttrs; nothing is built, no IFD.
#
# Stage attributes read (all optional except allowedBuildDrvs):
#   name, buildPure (check is a no-op unless true), allowedBuildDrvs,
#   stdenv, stdenvNoCC, transparent (list of drvs), extraAllowedSources
#   (paths or store-path strings), allowLockFods (default true),
#   purityIgnoreAttrs (default: disallowedReferences/disallowedRequisites --
#   things the build is checked *against*, at any depth incl. outputChecks),
#   fetch (default: lib/sources.nix of the lock), purityChecker (see below).
#
# Sharing the memo: `forStage stage` builds the per-stage memo.  mkStage should
# store `purityChecker = purity.forStage <the stage>` once; check /
# assertBuildPure / violations use it when present, so the stdenv and wrapper
# drvAttrs are walked once per stage instead of once per package.
#
# Cycle hazard: allowedBuildDrvs usually contains the stage's own packages.
# `check` therefore guards only `drvPath` (what nix build / nix-eval-jobs
# read), never `outPath` (what dependents interpolate), and drvPathOf reads
# the drvPath from the outPath's context; build the set with `drvSet`, never
# from `.drvPath` of checked derivations, or evaluation recurses forever.
{ lib, nixpkgsSrc, repo, lock, fetch }:
let
  inherit (builtins) attrNames concatLists convertHash elem filter getContext head isAttrs
    isList isPath isString length listToAttrs mapAttrs match readDir readFileType storeDir
    stringLength substring unsafeDiscardStringContext;

  defaultRoots = import ./allowed-sources.nix { inherit nixpkgsSrc repo; };

  # drvPath of a derivation value, read from its outPath's context (does not
  # force a guarded `drvPath`); null for a "derivation" without context
  drvPathOf = v:
    let ks = attrNames (getContext v.outPath);
    in if ks == [ ] then null else head ks;

  # /nix/store/<32 hash>-<name> -> <name>
  storeName = k: substring (stringLength storeDir + 34) (-1) k;
  drvName = k: lib.removeSuffix ".drv" (storeName k);
  isDrvKey = lib.hasSuffix ".drv";

  # ---------------------------------------------------------------- sources
  under = roots: s: lib.any (r: s == r || lib.hasPrefix (r + "/") s) roots;

  # name -> store paths of every file/dir under the roots with that name.
  # readDir only; a candidate is copied (hashed) the first time a context
  # entry with its name is looked up.
  validName = n: match "[A-Za-z0-9+_?=-][A-Za-z0-9+._?=-]*" n != null;
  treeEntries = root:
    let
      go = dir: concatLists (lib.mapAttrsToList (n: t:
        let p = dir + "/${n}"; in
        lib.optionals (validName n) ([ { name = n; path = p; } ] ++ lib.optionals (t == "directory") (go p)))
        (readDir dir));
    in [ { name = baseNameOf (toString root); path = root; } ]
       ++ lib.optionals (readFileType root == "directory") (go root);
  mkSourceIndex = roots:
    mapAttrs (_: es: map (e: unsafeDiscardStringContext "${e.path}") es)
      (lib.groupBy (e: e.name) (lib.concatMap treeEntries (filter isPath roots)));
  defaultIndex = mkSourceIndex defaultRoots;

  # ---------------------------------------------------------------- lock FODs
  lockSha256 = lib.mapAttrs' (n: s: lib.nameValuePair s.sha256 n) lock.srpms;
  toBase16 = algo: h:
    if match "[0-9a-f]{64}" h != null then h
    else convertHash ({ hash = h; toHashFormat = "base16"; }
      // lib.optionalAttrs (algo != null && algo != "") { hashAlgo = algo; });
  isLockFod = v:
    let
      a = v.drvAttrs or { };
      h = a.outputHash or null;
      algo = a.outputHashAlgo or null;
    in
    h != null && h != "" && elem algo [ null "" "sha256" ] && lockSha256 ? ${toBase16 algo h};
  # drvPath -> SRPM name, for lock FODs reached only through a string context
  # (forced only when such a reference is not otherwise allowed: ~0.75 s, once)
  mkLockFodDrvs = f: lib.mapAttrs' (n: _: lib.nameValuePair (drvPathOf (f.fetchSrpm n)) n) lock.srpms;
  defaultLockFodDrvs = mkLockFodDrvs fetch;

  # derivations the check descends into although they are not in allowedBuildDrvs
  looksTransparent = v:
    (v ? mkDerivation && v ? hasCC)            # nixpkgs generic stdenv
    || (v ? suffixSalt && v ? nativeTools);    # nixpkgs cc-wrapper / bintools-wrapper

  transparentSeeds = stage:
    let
      sd = stage.stdenv or null;
      cc = if sd != null && (sd.hasCC or false) then sd.cc else null;
      bt = if lib.isDerivation cc then cc.bintools or null else null;
    in filter lib.isDerivation ([ sd (stage.stdenvNoCC or null) cc bt ] ++ stage.transparent or [ ]);

  allowedSourcesFor = stage: defaultRoots ++ stage.extraAllowedSources or [ ];

  # ---------------------------------------------------------------- the walk
  forStage = stage:
    let
      stageName = stage.name or "?";
      allowed = stage.allowedBuildDrvs or { };
      allowLockFods = stage.allowLockFods or true;
      ignored = stage.purityIgnoreAttrs or [ "disallowedReferences" "disallowedRequisites" ];
      extras = stage.extraAllowedSources or [ ];
      rootStrings = map toString (defaultRoots ++ extras);
      extraIndex = mkSourceIndex extras;
      lockFodDrvs = if stage ? fetch then mkLockFodDrvs stage.fetch else defaultLockFodDrvs;

      sourceOk = k:
        under rootStrings k
        || elem k (defaultIndex.${storeName k} or [ ])
        || elem k (extraIndex.${storeName k} or [ ]);

      seeds = listToAttrs (map (d: lib.nameValuePair (drvPathOf d) d) (transparentSeeds stage));
      # chains in memo entries are relative to the transparent derivation
      memo = mapAttrs (_: d: walkAttrs 2 "" d.drvAttrs) seeds;

      vio = kind: key: chain: [ { inherit kind key chain; } ];
      enter = chain: name: vs: map (x: x // { chain = "${chain} > ${name}${x.chain}"; }) vs;

      ctxViolations = chain: s:
        let ctx = getContext s; in
        lib.concatMap (k:
          let c = ctx.${k}; in
          if isDrvKey k || c ? outputs || c ? allOutputs then
            if allowed ? ${k} then [ ]
            else if memo ? ${k} then enter chain (drvName k) memo.${k}
            else if allowLockFods && lockFodDrvs ? ${k} then [ ]
            else vio "derivation" k chain
          else if sourceOk k then [ ]
          else vio "source" k chain)
          (attrNames ctx);

      drvViolations = budget: chain: v:
        let p = drvPathOf v; in
        if p == null then [ ]
        else if allowed ? ${p} then [ ]
        else if memo ? ${p} then enter chain (drvName p) memo.${p}
        else if allowLockFods && isLockFod v then [ ]
        else if budget > 0 && looksTransparent v then
          enter chain (drvName p) (walkAttrs (budget - 1) "" v.drvAttrs)
        else vio "derivation" p chain;

      walk = budget: chain: v:
        if isString v then ctxViolations chain v
        else if isPath v then (if under rootStrings (toString v) then [ ] else vio "path" (toString v) chain)
        else if isList v then concatLists (lib.imap0 (i: walk budget "${chain}[${toString i}]") v)
        else if isAttrs v then
          if lib.isDerivation v then drvViolations budget chain v
          else if v ? __toString then walk budget chain (v.__toString v)
          else if v ? outPath then walk budget "${chain}.outPath" v.outPath
          else walkAttrs budget chain v
        else [ ];
      walkAttrs = budget: chain: as:
        lib.concatMap (n: if elem n ignored then [ ] else walk budget "${chain}.${n}" as.${n}) (attrNames as);

      label = x: if lib.isDerivation x then x.name or "derivation" else "<attrs>";
      violations = x: if lib.isDerivation x then walkAttrs 2 "" x.drvAttrs else walkAttrs 2 "" x;

      # one line per offending store path, with its shortest attribute chain
      report = x:
        let
          vs = violations x;
          byKey = lib.groupBy (v: v.key) vs;
          firsts = lib.sort (a: b: stringLength a.chain < stringLength b.chain)
            (lib.mapAttrsToList (_: l: (head (lib.sort (a: b: stringLength a.chain < stringLength b.chain) l))
              // { n = length l; }) byKey);
          shown = lib.take 25 firsts;
          what = v:
            if v.kind == "derivation" then "derivation ${drvName v.key} (${v.key})"
            else if v.kind == "source" then "source ${v.key} (not a copy of an allowed source file)"
            else "path ${v.key} (not under an allowed source root)";
          line = v: "  - ${what v}\n      via ${label x}${v.chain}"
            + lib.optionalString (v.n > 1) " (+${toString (v.n - 1)} more chain(s))";
        in
        if vs == [ ] then ""
        else "el-nixos purity: ${label x} is not build-pure for stage ${stageName}"
          + " (${toString (length firsts)} offending store path(s)):\n"
          + lib.concatMapStringsSep "\n" line shown
          + lib.optionalString (length firsts > 25) "\n  ... ${toString (length firsts - 25)} more"
          + "\n  allowed: stage.allowedBuildDrvs, lock FODs (SRPM hashes), sources under lib/rocky/allowed-sources.nix"
          + " ('>' = descended into a transparent stdenv/wrapper derivation)";

      assertBuildPure = x: if violations x == [ ] then x else throw (report x);

      # guards drvPath only (see the header: cycle hazard)
      check = drv:
        let guard = p: builtins.seq (assertBuildPure drv) p; in
        drv // { drvPath = guard drv.drvPath; }
        // lib.genAttrs (drv.outputs or [ ]) (o: drv.${o} // { drvPath = guard drv.${o}.drvPath; });
    in
    { inherit violations report assertBuildPure check; memoKeys = attrNames memo; };

  checkerFor = stage: stage.purityChecker or (forStage stage);
in
{
  inherit drvPathOf forStage allowedSourcesFor defaultRoots;
  allowedSources = defaultRoots;

  # allowedBuildDrvs from a list of derivations (multi-output: any output)
  drvSet = drvs: listToAttrs (map (d: lib.nameValuePair (drvPathOf d) (d.name or "")) drvs);

  violations = stage: (checkerFor stage).violations;           # [ { kind key chain } ]
  report = stage: (checkerFor stage).report;                   # "" when pure
  assertBuildPure = stage: (checkerFor stage).assertBuildPure; # identity or throw
  # mkRpmPackage hook (design §11.1): no-op unless stage.buildPure
  check = stage: drv: if stage.buildPure or false then (checkerFor stage).check drv else drv;
}
