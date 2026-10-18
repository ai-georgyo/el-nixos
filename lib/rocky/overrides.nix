# Per-package overrides packages/<srpm>/default.nix (docs/nix-native-design.md
# §8.1): a typed schema with defaults, validation and the loader.  Every field
# is documented in packages/README-overrides.md (checks.nn-names verifies that
# each field is mentioned there).
#
#   defaults                 the value of every field when no file / no key
#   errors file attrs        [ "<file>: ..." ]  (all problems, never throws)
#   validate file attrs      defaults // attrs, nested records filled; throws the
#                            joined errors (catchable with builtins.tryEval)
#   load { srpm, stage, rocky ? { }, dir ? packagesDir }
#                            validated overrides of <dir>/<srpm>/default.nix, or
#                            `defaults` if the file does not exist
#   overridesFor { stage, rocky ? { } } srpm
#                            the same, curried: mkRpmPackage gets
#                            `overridesFor { inherit stage rocky; }` (§11.1)
#   fileFor srpm             the override file's path, or null
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
    if lib.isDerivation v then "a derivation"
    else if builtins.isAttrs v then "a set"
    else if builtins.isString v then "string ${builtins.toJSON (lib.substring 0 40 v)}"
    else if builtins.isPath v then "path ${toString v}"
    else if builtins.isList v then "a list"
    else if v == null then "null"
    else "${builtins.typeOf v} ${builtins.toJSON v}";

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
      from = required str;
      to = required str;
      count = field positiveInt 1;
    })) [ ];
    env = field (attrsOf envValue) { };
    doCheck = field bool false;
    prefixView = field bool true;
    strictFhs = field bool false;
    inputs = field (record "{ add; addNative; drop; }" {
      add = field (listOf pathish) [ ];
      addNative = field (listOf pathish) [ ];
      drop = field (listOf str) [ ];
    }) { add = [ ]; addNative = [ ]; drop = [ ]; };
    stage = field (nullOr str) null;
    # outputs
    prefixSubpackage = field (nullOr str) null;
    mergeOutputs = field (listOf (listOf str)) [ ];
    layout = field (attrsOf str) { };
    runtimeSearchPaths = field (attrsOf identifier) { };
    unionDirs = field (attrsOf str) { };
    danglingOk = field (listOf str) [ ];
    opaqueRefs = field (listOf str) [ ];
    forward = field (record "{ deny; }" {
      deny = field (listOf str) [ ];
    }) { deny = [ ]; };
    noPatchelf = field (listOf str) [ ];
    allowUnresolvedNeeded = field (listOf str) [ ];
    fhsAllowlist = field (attrsOf str) { };
    lateBind = field (attrsOf (record "{ interpreters; libs; }" {
      interpreters = field (listOf str) [ ];
      libs = field (listOf str) [ ];
    })) { };
    lateReferrers = field (attrsOf (listOf str)) { };
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
    ++ lib.concatLists (lib.mapAttrsToList (k: _:
      lib.optional (builtins.match "[A-Za-z_][A-Za-z0-9_]*" k == null)
        "`defines.${k}`: not a macro name") v.defines)
    ++ lib.concatLists (lib.mapAttrsToList (k: _:
      lib.optional (builtins.match "_?[A-Za-z][A-Za-z0-9_]*" k == null)
        "`layout.${k}`: not a macro name") v.layout);

  errors = file: v:
    let
      typeErrors = top.errors "" v;
      all = if typeErrors != [ ] then typeErrors else semanticErrors (top.fill v);
    in
    map (e: "${file}: ${e}") all;

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
  inherit schema defaults errors validate load types;
  fileFor = fileFor' packagesDir;
  overridesFor = { stage, rocky ? { } }: srpm: load { inherit srpm stage rocky; };
}
