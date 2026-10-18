# Output and store names of relocated packages: one Nix output per RPM
# subpackage (docs/nix-native-design.md §2.12, §3.1, §3.2, §0.4).  Pure
# functions over the lock data; no derivations.
#
#   outputName { srpm, subpkg, prefix }      -> "out" | "dev" | "lib" | "debug" | "<X>" | ...
#   outputsFor { srpm, sub, mergeOutputs ? [ ], prefixSubpackage ? null }
#     sub = a lock/rocky-<rel>/subpackages.json entry (tools/lock_subpackages.py):
#           { names = [ <subpackage> ... ];      debug packages excluded (§3.2)
#             debug = [ <name>-debuginfo ... ];  the debug packages the spec builds
#                                                (or a bool: whether it builds any)
#             prefix = "<subpackage>"; shipped = { <name> = bool; }; ... }
#           (debug names inside `names` are accepted too; absent `debug` = true)
#     -> { outputs        [ "out" <sorted ...> "debug" "logs" ]  (debug iff any debug package)
#          rpmOutputs     { <subpackage> = <output>; }   every subpackage, merged ones alias
#                                                        their representative, debug ones -> debug
#          shippedRpmOutputs  the same minus unshipped (what rocky.rpm.* aliases)
#          unshipped      { <subpackage> = <output>; }   shipped = false (passthru.unshipped);
#                                                        debug packages are never in it
#          merged         { <member> = <representative>; }
#          prefix         the prefix subpackage (-> out) }
#   storeName { srpm, version, release, output ? "out" }  -> "<srpm>-<v>-<r>[-<output>]"
#   defaultPrefix srpm names                 eponymous > <srpm>-libs > null
#
# Name rule (§2.12): prefix subpackage -> out; <srpm>-devel -> dev; <srpm>-libs
# -> lib (unless it is the prefix); *-debuginfo / *-debugsource -> debug;
# <srpm>-X -> X; other names verbatim; then [^A-Za-z0-9_] -> _.  Collisions
# between outputs after that mapping -> every colliding subpackage falls back to
# its full sanitized name (eval error if that still collides).
#
# Two refinements of the rule, both measured on the 6907 RPM names of Rocky
# 10.2 (docs/research/nix-native/experiments/names.md):
#   * a short name that is not a shell identifier (xorg-x11-fonts-100dpi ->
#     "100dpi": setup.sh exports every output as a variable) or that is
#     `reserved` (attribute/variable names of the derivation: "src" would
#     become $src, "system", "all", our own "debug"/"logs"/"out") also falls
#     back to the full sanitized name;
#   * a full name that is still invalid gets a leading "_".
# A merge group containing the prefix subpackage is always `out`, whatever
# its first member (the first member is the representative otherwise).
#
# Heads-up for mkRpmPackage: the names include `dev`, `doc`, `info`, `bin`,
# `lib`, `static` (all of them occur in the 10.2 lock), which nixpkgs'
# multiple-outputs.sh treats specially: `_multioutDocs` / `_multioutDevs`
# (preFixupHooks) move share/{doc,info,man}, include, lib/pkgconfig, ... of
# every other output into $doc / $info / $dev, `_multioutPropagateDev`
# (postFixupHooks) writes $dev/nix-support/propagated-build-inputs, and
# `_multioutConfig` adds --bindir etc. to configureFlags.  The partition is
# final, so the derivation must switch all of them off (`moveToDev = false`,
# `propagatedBuildOutputs = ""`, `setOutputFlags = false`, and drop
# `_multioutDocs` from preFixupHooks; there is no `dontMoveDocs`).
{ lib }:
let
  storeNameChars = import ../store-name.nix; # '^' '~' -> '_' (RPM versions)

  # [^A-Za-z0-9_] -> _
  sanitize = s:
    lib.concatMapStrings (x: if lib.isList x then "_" else x) (builtins.split "[^A-Za-z0-9_]" s);

  isIdentifier = s: builtins.match "[A-Za-z_][A-Za-z0-9_]*" s != null;

  # the lock generator's rule (tools/lock_subpackages.py DEBUG)
  isDebugName = n: lib.hasSuffix "-debuginfo" n || lib.hasSuffix "-debugsource" n
    || lib.hasInfix "-debuginfo-common-" n;

  # Output names that would shadow attributes of the derivation (nix
  # `derivation`, stdenv.mkDerivation, passthru) or variables setup.sh
  # relies on.  "out", "debug", "logs" are produced by the rule itself only.
  reserved = [
    "out" "debug" "logs"
    "all" "args" "builder" "drvAttrs" "drvPath" "env" "inputDerivation" "meta"
    "name" "outPath" "outputName" "outputSpecified" "outputs" "override"
    "overrideAttrs" "overrideDerivation" "passthru" "patches" "phases" "pname"
    "prefix" "raw" "shell" "src" "srcs" "stdenv" "system" "type" "version"
  ];

  usable = s: isIdentifier s && !(lib.elem s reserved);

  # full sanitized subpackage name, made a valid identifier if it is not one
  fullName = subpkg:
    let s = sanitize subpkg; in if usable s then s else "_" + s;

  # The name rule for one subpackage, without collision context.
  outputName = { srpm, subpkg, prefix }:
    if subpkg == prefix then "out"
    else if isDebugName subpkg then "debug"
    else if subpkg == "${srpm}-devel" then "dev"
    else if subpkg == "${srpm}-libs" then "lib"
    else
      let short = sanitize (lib.removePrefix "${srpm}-" subpkg);
      in if usable short then short else fullName subpkg;

  # §3.1 without the filelist tier (the lock generator applies it and writes
  # subpackages.json.prefix): eponymous > <srpm>-libs.
  defaultPrefix = srpm: names:
    if lib.elem srpm names then srpm
    else if lib.elem "${srpm}-libs" names then "${srpm}-libs"
    else null;

  outputsFor = { srpm, sub, mergeOutputs ? [ ], prefixSubpackage ? null }:
    let
      where = "names.outputsFor (${srpm})";
      # `debug`: the lock's list of debug packages, or a bool (absent = true)
      debugField = sub.debug or true;
      debugList = if lib.isList debugField then debugField else [ ];
      names = lib.unique (sub.names ++ debugList);
      prefix =
        if prefixSubpackage != null then prefixSubpackage
        else if sub.prefix or null != null then sub.prefix
        else defaultPrefix srpm names;
      shipped = n: sub.shipped.${n} or true;

      # ---- merges: member -> owner (the representative) -------------------
      groupErrors = lib.concatMap (g:
        if !(lib.isList g) || lib.length g < 2 || !(lib.all lib.isString g)
        then [ "mergeOutputs: ${builtins.toJSON g} is not a list of >= 2 subpackage names" ]
        else map (m: "mergeOutputs: `${m}` is not a subpackage of ${srpm}")
                 (lib.filter (m: !(lib.elem m names)) g)
          ++ map (m: "mergeOutputs: `${m}` is a debuginfo subpackage (all of them map to `debug`)")
                 (lib.filter isDebugName g)) mergeOutputs;
      members = lib.concatLists mergeOutputs;
      dupErrors = map (m: "mergeOutputs: `${m}` is in more than one group")
        (lib.unique (lib.filter (m: lib.count (x: x == m) members > 1) members));
      owner = g: if lib.elem prefix g then prefix else lib.head g;
      merged = lib.listToAttrs (lib.concatMap (g:
        map (m: lib.nameValuePair m (owner g)) (lib.filter (m: m != owner g) g)) mergeOutputs);
      rep = n: merged.${n} or n;

      # ---- names of the subpackages that own an output ---------------------
      owners = lib.filter (n: rep n == n && !(isDebugName n)) names;
      short = lib.genAttrs owners (n: outputName { inherit srpm prefix; subpkg = n; });
      shortCount = s: lib.count (n: short.${n} == s) owners;
      final = lib.mapAttrs (n: s: if s != "out" && shortCount s > 1 then fullName n else s) short;
      finals = lib.attrValues final;
      collisionErrors = map (s: "output `${s}` is produced by "
          + lib.concatStringsSep ", " (lib.filter (n: final.${n} == s) owners)
          + " even after falling back to full names")
        (lib.unique (lib.filter (s: lib.count (x: x == s) finals > 1) finals));

      errors =
        lib.optional (!(lib.isList debugField || lib.isBool debugField))
          "`debug` must be a list of debug package names or a bool, got ${builtins.typeOf debugField}"
        ++ map (n: "`debug` lists `${n}`, which is not a debuginfo/debugsource name")
          (lib.filter (n: !(isDebugName n)) debugList)
        ++ lib.optional (prefix == null)
          "no prefix subpackage: neither `${srpm}` nor `${srpm}-libs` exists; set prefixSubpackage (or subpackages.json prefix)"
        ++ lib.optional (prefix != null && !(lib.elem prefix names))
          "prefix subpackage `${prefix}` is not a subpackage of ${srpm}"
        ++ lib.optional (prefix != null && isDebugName prefix)
          "prefix subpackage `${prefix}` is a debuginfo subpackage"
        ++ groupErrors ++ dupErrors ++ collisionErrors;

      rpmOutputs = lib.genAttrs names (n: if isDebugName n then "debug" else final.${rep n});
      # the lock's `shipped` covers `names` only; debug packages are never "unshipped"
      unshipped = lib.filterAttrs (n: _: !(isDebugName n) && !(shipped n)) rpmOutputs;
      hasDebug = lib.any isDebugName names || debugField == true;
    in
    if errors != [ ] then throw "${where}: ${lib.concatStringsSep "; " errors}"
    else {
      outputs = [ "out" ] ++ lib.sort lib.lessThan (lib.remove "out" finals)
        ++ lib.optional hasDebug "debug" ++ [ "logs" ];
      inherit rpmOutputs unshipped merged prefix;
      shippedRpmOutputs = lib.filterAttrs (n: _: shipped n) rpmOutputs;
    };

  storeName = { srpm, version, release, output ? "out" }:
    storeNameChars "${srpm}-${version}-${release}" + lib.optionalString (output != "out") "-${output}";
in
{
  inherit sanitize isIdentifier isDebugName reserved fullName outputName defaultPrefix
    outputsFor storeName;
}
