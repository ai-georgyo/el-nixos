# Per-package overrides packages/<srpm>/default.nix (docs/nix-native-design.md
# §8.1): a typed schema with defaults, validation and the loader.  Every field
# is documented in packages/README-overrides.md (checks.nn-names verifies that
# each field is mentioned there).
#
#   defaults                 the value of every field when no file / no key
#   errors file attrs        [ "<file>: ..." ]  (all problems, never throws on
#                            the value's shape: functions, derivations, ... are
#                            described, not serialized)
#   validate file attrs      defaults // attrs, nested records filled; throws the
#                            joined errors (catchable with builtins.tryEval)
#   load { srpm, stage, rocky ? { }, dir ? packagesDir }
#                            validated overrides of <dir>/<srpm>/default.nix, or
#                            `defaults` if the file does not exist
#   overridesFor { stage, rocky ? { } } srpm
#                            the same, curried: mkRpmPackage gets
#                            `overridesFor { inherit stage rocky; }` (§11.1)
#   fileFor srpm             the override file's path, or null
#   outputErrors file ov outs  [ "<file>: ..." ]: fields naming outputs (layout
#                            values, lateBind keys, lateReferrers keys and values)
#                            checked against outs = names.outputsFor {...}
#   checkOutputs file ov outs  ov, or throws those errors (for mkRpmPackage)
#
# Override files are `{ lib, stage, rocky }: { ... }` (only the arguments the
# function names are passed, as callPackage does; a plain attrset is accepted
# too).  Unknown keys at any level are errors naming the key and the file.
{ lib, packagesDir, unions }:
let
  # ---- a tiny type language: { name; errors = where: v: [ msg ]; } ----------
  # (errors are collected, not thrown, so one evaluation reports everything and
  # tests can inspect the messages; `fill` adds record defaults.)
  describe = v:
    if lib.isFunction v then "a function (missing an argument?)"
    else if lib.isDerivation v then "a derivation"
    else if builtins.isAttrs v then "a set"
    else if builtins.isString v then "string ${builtins.toJSON (lib.substring 0 40 v)}"
    else if builtins.isPath v then "path ${toString v}"
    else if builtins.isList v then "a list"
    else if v == null then "null"
    else "${builtins.typeOf v} ${builtins.toJSON v}";

  isOutputName = v: builtins.isString v && builtins.match "[A-Za-z_][A-Za-z0-9_]*" v != null;
  isOutputGlob = v: isOutputName v
    || (builtins.isString v && builtins.match "[]A-Za-z0-9_*?![-]+" v != null
        && builtins.match ".*[*?[].*" v != null);
  isRelPath = v: builtins.isString v && v != "" && !(lib.hasPrefix "/" v) && !(lib.hasSuffix "/" v)
    && lib.all (c: !(lib.elem c [ "" "." ".." ])) (lib.splitString "/" v);

  # path of a key below `where` ("" = the top level)
  sub = where: k: if where == "" then k else "${where}.${k}";
  show = where: if where == "" then "the top level" else "`${where}`";

  simple = name: pred: {
    inherit name;
    errors = where: v: lib.optional (!(pred v)) "${show where}: expected ${name}, got ${describe v}";
    fill = v: v;
  };

  types = rec {
    str = simple "a string" builtins.isString;
    bool = simple "a bool" builtins.isBool;
    # a store object an input or a source may be given as
    pathish = simple "a path, string or derivation"
      (v: builtins.isPath v || builtins.isString v || lib.isDerivation v);
    envValue = simple "a string, number, bool, path, derivation or null"
      (v: v == null || builtins.isString v || builtins.isInt v || builtins.isBool v
          || builtins.isPath v || lib.isDerivation v);
    identifier = simple "an identifier ([A-Za-z_][A-Za-z0-9_]*)"
      (v: builtins.isString v && builtins.match "[A-Za-z_][A-Za-z0-9_]*" v != null);
    # rpmbuild --define drops everything after a raw newline (§1.2)
    defineValue = simple "a single-line string or an int"
      (v: builtins.isInt v || (builtins.isString v && !(lib.hasInfix "\n" v)));
    positiveInt = simple "an int >= 1" (v: builtins.isInt v && v >= 1);
    nonEmptyStr = simple "a non-empty string" (v: builtins.isString v && v != "");
    # a Nix output name (lib/rocky/names.nix makes them shell identifiers)
    outputName = simple "an output name ([A-Za-z_][A-Za-z0-9_]*)" isOutputName;
    # an output name or a glob over output names (`langpack_*`)
    outputGlob = simple "an output name or a glob over output names" isOutputGlob;
    # an output-relative path: no leading or trailing `/`, no `.`/`..`/empty component
    relPath = simple "an output-relative path (lib/locale)" isRelPath;
    # "<output glob>" or "<output glob>:<rel glob>" (PLAN.md output pattern)
    outputPattern = simple "an output pattern (\"<output glob>[:<rel glob>]\")"
      (v: builtins.isString v && v != "" && !(lib.hasPrefix ":" v) && !(lib.hasPrefix "/" v));
    # an output-relative glob (lib64/lib*.so*)
    relGlob = simple "an output-relative glob" (v: builtins.isString v && v != "" && !(lib.hasPrefix "/" v));

    nullOr = t: {
      name = "null or ${t.name}";
      errors = where: v: if v == null then [ ] else t.errors where v;
      fill = v: if v == null then v else t.fill v;
    };
    listOf = t: {
      name = "a list of ${t.name}";
      errors = where: v:
        if !(builtins.isList v) then [ "${show where}: expected a list of ${t.name}, got ${describe v}" ]
        else lib.concatLists (lib.imap0 (i: x: t.errors "${where}[${toString i}]" x) v);
      fill = map t.fill;
    };
    attrsOf = t: {
      name = "a set of ${t.name}";
      errors = where: v:
        if !(builtins.isAttrs v) || lib.isDerivation v
        then [ "${show where}: expected a set of ${t.name}, got ${describe v}" ]
        else lib.concatLists (lib.mapAttrsToList (k: x: t.errors (sub where k) x) v);
      fill = lib.mapAttrs (_: t.fill);
    };
    # fields = { <key> = { type; default; } or { type; required = true; }; }
    record = name: fields: {
      inherit name;
      errors = where: v:
        if !(builtins.isAttrs v) || lib.isDerivation v
        then [ "${show where}: expected ${name}, got ${describe v}" ]
        else
          map (k: "unknown key `${sub where k}` (known: ${lib.concatStringsSep ", " (lib.attrNames fields)})")
            (lib.attrNames (removeAttrs v (lib.attrNames fields)))
          ++ lib.concatLists (lib.mapAttrsToList (k: f:
            if v ? ${k} then f.type.errors (sub where k) v.${k}
            else lib.optional (f.required or false) "${show where}: missing required key `${k}`") fields);
      fill = v: lib.mapAttrs (k: f: if v ? ${k} then f.type.fill v.${k} else f.default)
        (lib.filterAttrs (k: f: v ? ${k} || f ? default) fields);
    };
  };

  field = type: default: { inherit type default; };
  required = type: { inherit type; required = true; };

  # ---- the schema (§8.1) ------------------------------------------------------
  schema = with types; {
    # recipe
    defines = field (attrsOf defineValue) { };
    bconds = field (record "{ with; without; }" {
      "with" = field (listOf str) [ ];
      without = field (listOf str) [ ];
    }) { "with" = [ ]; without = [ ]; };
    configSite = field (nullOr pathish) null;
    nixPatches = field (listOf pathish) [ ];
    prepScript = field str "";
    specSubstitutions = field (listOf (record "{ from; to; count; }" {
      from = required nonEmptyStr;
      to = required str;
      count = field positiveInt 1;
    })) [ ];
    env = field (attrsOf envValue) { };
    doCheck = field bool false;
    prefixView = field bool true;
    strictFhs = field bool false;
    inputs = field (record "{ add; addBuildOnly; addNative; drop; buildRequires; }" {
      add = field (listOf pathish) [ ];
      # host inputs (cc-wrapper input, /usr view) the outputs must not
      # reference even when Rocky-built: never runtime inputs (glibc:
      # kernel-headers, M1 closure = siblings + libgccForGlibc)
      addBuildOnly = field (listOf pathish) [ ];
      addNative = field (listOf pathish) [ ];
      drop = field (listOf str) [ ];
      # extra BuildRequires (RPM names), resolved like builddeps.json's
      # (stage package, stage fallback, else an eval error)
      buildRequires = field (listOf nonEmptyStr) [ ];
    }) { add = [ ]; addBuildOnly = [ ]; addNative = [ ]; drop = [ ]; buildRequires = [ ]; };
    stage = field (nullOr str) null;
    # false: the stage libc is build-only (outputs without programs or
    # libraries, e.g. kernel-headers): not a runtime input, not allowed in
    # any output
    runtimeLibc = field bool true;
    # outputs
    prefixSubpackage = field (nullOr str) null;
    # null: every subpackage of subpackages.json; else exactly the
    # subpackages this build produces (bconds switch the rest off)
    builtSubpackages = field (nullOr (listOf nonEmptyStr)) null;
    mergeOutputs = field (listOf (listOf str)) [ ];
    layout = field (attrsOf outputName) { };
    runtimeSearchPaths = field (attrsOf identifier) { };
    unionDirs = field (attrsOf str) { };
    danglingOk = field (listOf relPath) [ ];
    opaqueRefs = field (listOf relGlob) [ ];
    forward = field (record "{ deny; }" {
      deny = field (listOf relGlob) [ ];
    }) { deny = [ ]; };
    noPatchelf = field (listOf relGlob) [ ];
    # { "<rel pattern>" = "<reason>"; }: regular files of a non-prefix output
    # that the prefix output names where no forwarding stub can serve (the
    # owner references the prefix output): moved into the prefix output, the
    # owner keeps a symlink (rocky-partition PLAN.md; glibc's locale.alias,
    # C.utf8)
    pullToPrefix = field (attrsOf str) { };
    # rocky-partition keys beyond §8.1 (tools/rocky-partition/PLAN.md)
    prefixRelativeOk = field (listOf outputPattern) [ ];
    integrityOk = field (listOf outputPattern) [ ];
    systemLibDirs = field (nullOr (listOf nonEmptyStr)) null;
    allowUnresolvedNeeded = field (listOf str) [ ];
    fhsAllowlist = field (attrsOf str) { };
    lateBind = field (attrsOf (record "{ interpreters; libs; }" {
      interpreters = field (listOf str) [ ];
      libs = field (listOf str) [ ];
    })) { };
    lateReferrers = field (attrsOf (listOf outputGlob)) { };
  };

  top = types.record "an overrides set" schema;
  defaults = lib.mapAttrs (_: f: f.default) schema;

  # rules across fields (only checked once the types are right)
  semanticErrors = v:
    let
      members = lib.concatLists v.mergeOutputs;
      lateKeys = lib.attrNames v.lateBind;
    in
    map (g: "`mergeOutputs`: group ${builtins.toJSON g} needs at least 2 subpackages")
      (lib.filter (g: lib.length g < 2) v.mergeOutputs)
    ++ map (m: "`mergeOutputs`: `${m}` is in more than one group")
      (lib.unique (lib.filter (m: lib.count (x: x == m) members > 1) members))
    ++ lib.concatLists (lib.mapAttrsToList (rel: var:
      lib.optional (!(lib.elem var unions.vars))
        "`runtimeSearchPaths.${rel}`: `${var}` is not a union variable (lib/rocky/unions.nix: ${lib.concatStringsSep " " unions.vars})")
      v.runtimeSearchPaths)
    ++ map (k: "`lateReferrers.${k}`: `${k}` is not a lateBind output")
      (lib.filter (k: !(lib.elem k lateKeys)) (lib.attrNames v.lateReferrers))
    ++ map (k: "`lateBind.${k}`: `${k}` is not an output name")
      (lib.filter (k: !(isOutputName k)) lateKeys)
    ++ lib.concatMap (f: map (k: "`${f}.${k}`: `${k}` is not an output-relative path")
      (lib.filter (k: !(isRelPath k)) (lib.attrNames v.${f}))) [ "runtimeSearchPaths" "unionDirs" "pullToPrefix" ]
    ++ lib.concatLists (lib.mapAttrsToList (k: _:
      lib.optional (builtins.match "[A-Za-z_][A-Za-z0-9_]*" k == null)
        "`defines.${k}`: not a macro name") v.defines)
    # env: identifier keys go into the derivation's structured `env`; other
    # keys (make variables like glibc's user-defined-trusted-dirs) only onto
    # rpmbuild's command line as `env 'k=v'` (mkRpmPackage), so they must be
    # valid `env` assignments
    ++ lib.concatLists (lib.mapAttrsToList (k: _:
      lib.optional (builtins.match "[A-Za-z_][A-Za-z0-9_.+-]*" k == null)
        "`env.${k}`: not a variable name (letters, digits, _ . + -, not starting with a digit)") v.env)
    ++ lib.concatLists (lib.mapAttrsToList (k: _:
      lib.optional (builtins.match "_?[A-Za-z][A-Za-z0-9_]*" k == null)
        "`layout.${k}`: not a macro name") v.layout);

  errors = file: v:
    let
      typeErrors = top.errors "" v;
      all = if typeErrors != [ ] then typeErrors else semanticErrors (top.fill v);
    in
    map (e: "${file}: ${e}") all;

  # glob over output names -> regex (the charset is checked by outputGlob)
  globRegex = g: builtins.replaceStrings [ "*" "?" "[!" ] [ ".*" "." "[^" ] g;
  matchesSome = outs: g: lib.any (o: builtins.match (globRegex g) o != null) outs;

  outputErrors = file: v: outs:
    let
      known = outs.outputs;
      bad = what: o: lib.optional (!(lib.elem o known)) "${what}: `${o}` is not an output (outputs: ${lib.concatStringsSep " " known})";
    in
    map (e: "${file}: ${e}") (
      lib.concatLists (lib.mapAttrsToList (k: o: bad "`layout.${k}`" o) (v.layout or { }))
      ++ lib.concatMap (o: bad "`lateBind.${o}`" o) (lib.attrNames (v.lateBind or { }))
      ++ lib.concatLists (lib.mapAttrsToList (k: gs:
        bad "`lateReferrers.${k}`" k
        ++ map (g: "`lateReferrers.${k}`: `${g}` matches no output")
          (lib.filter (g: !(matchesSome known g)) gs)) (v.lateReferrers or { })));

  checkOutputs = file: v: outs:
    let es = outputErrors file v outs; in
    if es != [ ] then throw ("overrides name unknown outputs:\n  " + lib.concatStringsSep "\n  " es)
    else v;

  validate = file: v:
    let es = errors file v; in
    if es != [ ] then throw ("invalid overrides:\n  " + lib.concatStringsSep "\n  " es)
    else top.fill v;

  relFile = srpm: "packages/${srpm}/default.nix";

  fileFor' = dir: srpm:
    let f = dir + "/${srpm}/default.nix"; in if builtins.pathExists f then f else null;

  call = f: ctx:
    if lib.isFunction f then
      let fa = lib.functionArgs f; in f (if fa == { } then ctx else builtins.intersectAttrs fa ctx)
    else f;

  load = { srpm, stage, rocky ? { }, dir ? packagesDir, name ? relFile srpm }:
    let f = fileFor' dir srpm; in
    if f == null then defaults
    else validate name (call (import f) { inherit lib stage rocky; });
in
{
  inherit schema defaults errors validate load types outputErrors checkOutputs;
  fileFor = fileFor' packagesDir;
  overridesFor = { stage, rocky ? { } }: srpm: load { inherit srpm stage rocky; };
}
