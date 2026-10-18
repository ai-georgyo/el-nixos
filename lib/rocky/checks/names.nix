# checks.nn-names: eval-time tests of nn.names, nn.overrides and nn.unions
# (lib/rocky/{names,overrides,unions}.nix), baked into a trivial derivation.
# Every test is evaluated (a throwing test counts as failed); the build prints
# the table and fails if any test failed.  One build-time test runs
# unions.profileScript on a fake profile root.
{ bootPkgs, lib, rpmsLock, lock, repo, self, ... }:
let
  inherit (self) names overrides unions;

  # a test: `value` must evaluate (deeply) to true
  test = name: value: detail:
    let r = builtins.tryEval (builtins.deepSeq value value); in
    { inherit name; ok = r.success && r.value == true; detail = toString detail; };
  throws = e: !(builtins.tryEval (builtins.deepSeq e e)).success;
  allUnique = l: lib.length (lib.unique l) == lib.length l;
  hasError = needles: es: lib.any (e: lib.all (n: lib.hasInfix n e) needles) es;

  rpmNames = srpm: lib.unique (map (k: rpmsLock.rpms.${k}.name) rpmsLock.bySrpm.${srpm});

  # ---- glibc ------------------------------------------------------------------
  glibcUnshipped = [ "glibc32" "sysroot-x86_64-el10-glibc" "compat-libpthread-nonshared" ];
  fixture = lib.importJSON ../tests/glibc-subpackages.json;
  glibcSub = names.subpackagesFor "glibc";       # the lock entry once it exists, else the fixture
  glibcMerge = [ [ "glibc" "glibc32" ] ];
  g = names.outputsFor { srpm = "glibc"; sub = glibcSub; mergeOutputs = glibcMerge; };
  gNoMerge = names.outputsFor { srpm = "glibc"; sub = glibcSub; };
  gRevMerge = names.outputsFor { srpm = "glibc"; sub = glibcSub; mergeOutputs = [ [ "glibc32" "glibc" ] ]; };
  nOut = lib.length g.outputs;
  middle = lib.sublist 1 (nOut - 3) g.outputs;
  lockHasGlibc = names.subpackages ? glibc;

  glibcTests = [
    (test "glibc fixture = rpms.json bySrpm.glibc + 3 unshipped"
      (lib.sort lib.lessThan fixture.names == lib.sort lib.lessThan (rpmNames "glibc" ++ glibcUnshipped)
        && lib.attrNames (lib.filterAttrs (_: s: !s) fixture.shipped) == lib.sort lib.lessThan glibcUnshipped
        && fixture.prefix == "glibc")
      "${toString (lib.length fixture.names)} subpackages, ${toString (lib.length (rpmNames "glibc"))} shipped")
    (test "glibc lock/subpackages.json entry = fixture"
      (!lockHasGlibc || (lib.sort lib.lessThan names.subpackages.glibc.names == fixture.names
        && names.subpackages.glibc.prefix == "glibc"
        && lib.filterAttrs (_: s: !s) names.subpackages.glibc.shipped == lib.filterAttrs (_: s: !s) fixture.shipped))
      (if lockHasGlibc then "compared" else "skipped: lock/rocky-${rpmsLock.release or "10.2"}/subpackages.json has no glibc entry yet"))
    (test "glibc: 224 subpackages -> 223 outputs + debug + logs"
      (lib.length glibcSub.names == 224 && nOut == 225) "${toString nOut} outputs")
    (test "glibc: out first, debug and logs last, the rest sorted and unique"
      (lib.head g.outputs == "out" && lib.sublist (nOut - 2) 2 g.outputs == [ "debug" "logs" ]
        && middle == lib.sort lib.lessThan middle && allUnique g.outputs)
      (lib.concatStringsSep " " (lib.take 6 g.outputs) + " ..."))
    (test "glibc: output names are shell identifiers, none reserved"
      (lib.all names.isIdentifier g.outputs
        && lib.all (o: !(lib.elem o names.reserved)) middle) "")
    (test "glibc: rpmOutputs"
      (g.rpmOutputs == g.rpmOutputs // {
        glibc = "out"; glibc32 = "out"; glibc-devel = "dev"; glibc-common = "common";
        glibc-langpack-de = "langpack_de"; glibc-minimal-langpack = "minimal_langpack";
        glibc-all-langpacks = "all_langpacks"; glibc-nss-devel = "nss_devel"; nss_db = "nss_db";
        libnsl = "libnsl"; glibc-static = "static"; glibc-doc = "doc";
        sysroot-x86_64-el10-glibc = "sysroot_x86_64_el10_glibc";
        compat-libpthread-nonshared = "compat_libpthread_nonshared";
      } && lib.length (lib.attrNames g.rpmOutputs) == 224
        && lib.all (o: lib.elem o g.outputs) (lib.attrValues g.rpmOutputs)
        && lib.subtractLists (lib.attrValues g.rpmOutputs) g.outputs == [ "debug" "logs" ])
      "every subpackage maps to an output; every output but debug/logs has a subpackage")
    (test "glibc: unshipped flagged, 221 shipped aliases"
      (g.unshipped == { glibc32 = "out"; sysroot-x86_64-el10-glibc = "sysroot_x86_64_el10_glibc";
          compat-libpthread-nonshared = "compat_libpthread_nonshared"; }
        && lib.length (lib.attrNames g.shippedRpmOutputs) == 221 && g.merged == { glibc32 = "glibc"; })
      "")
    (test "glibc: without the merge glibc32 is its own output (226)"
      (lib.length gNoMerge.outputs == 226 && gNoMerge.rpmOutputs.glibc32 == "glibc32") "")
    (test "glibc: a merge group containing the prefix is out whatever its order"
      (gRevMerge.outputs == g.outputs && gRevMerge.rpmOutputs.glibc32 == "out") "")
    (test "storeName"
      (names.storeName { srpm = "glibc"; version = "2.39"; release = "142.el10_2"; } == "glibc-2.39-142.el10_2"
        && names.storeName { srpm = "glibc"; inherit (lock.srpms.glibc) version release; output = "dev"; } == "glibc-2.39-142.el10_2-dev"
        && names.storeName { srpm = "x"; version = "1.0^20240101git"; release = "1~rc1"; } == "x-1.0_20240101git-1_rc1")
      "")
  ];

  # ---- other real SRPMs -------------------------------------------------------
  krb5 = names.outputsForSrpm { srpm = "krb5"; };
  perl = names.outputsForSrpm { srpm = "perl"; };
  fonts = names.outputsForSrpm { srpm = "xorg-x11-fonts"; prefixSubpackage = "xorg-x11-fonts-misc"; };
  realTests = [
    (test "krb5: no eponymous subpackage -> prefix krb5-libs = out"
      (krb5.prefix == "krb5-libs" && krb5.rpmOutputs.krb5-libs == "out"
        && krb5.outputs == [ "out" "dev" "libkadm5" "pkinit" "server" "server_ldap" "workstation" "xrealmauthz" "debug" "logs" ])
      (lib.concatStringsSep " " krb5.outputs))
    (test "krb5: prefixSubpackage override; -libs then becomes lib"
      (let k = names.outputsForSrpm { srpm = "krb5"; prefixSubpackage = "krb5-workstation"; };
       in k.rpmOutputs.krb5-workstation == "out" && k.rpmOutputs.krb5-libs == "lib") "")
    (test "perl: perl-lib / perl-libs collide on `lib` -> full names"
      (perl.rpmOutputs.perl-lib == "perl_lib" && perl.rpmOutputs.perl-libs == "perl_libs"
        && perl.rpmOutputs.perl-devel == "dev") "")
    (test "xorg-x11-fonts: 100dpi is not an identifier -> full name"
      (fonts.rpmOutputs.xorg-x11-fonts-100dpi == "xorg_x11_fonts_100dpi"
        && fonts.rpmOutputs.xorg-x11-fonts-Type1 == "Type1") "")
  ];

  # ---- every SRPM of the lock (shipped subpackages, fallback prefix) ----------
  # SRPMs without eponymous / -libs subpackage get the lock generator's
  # filelist-based prefix; until subpackages.json exists use the shortest name.
  sweep = lib.mapAttrs (srpm: _:
    let
      sub = names.fromRpms srpm;
      prefix = if sub.prefix != null then sub.prefix
        else lib.head (lib.sort (a: b: lib.stringLength a < lib.stringLength b || (lib.stringLength a == lib.stringLength b && a < b)) sub.names);
      r = builtins.tryEval (let o = names.outputsFor { inherit srpm; sub = sub // { inherit prefix; }; }; in builtins.deepSeq o o);
    in {
      ok = r.success && allUnique r.value.outputs && lib.all names.isIdentifier r.value.outputs
        && lib.head r.value.outputs == "out";
      ruleless = sub.prefix == null;
      outputs = if r.success then lib.length r.value.outputs else 0;
      # subpackages whose output is not the plain rule's: collisions, and
      # non-identifier / reserved short names (outputName's own fallback)
      collisions = if r.success
        then lib.length (lib.filter (n: names.outputName { inherit srpm prefix; subpkg = n; } != r.value.rpmOutputs.${n}) sub.names)
        else 0;
      refined = lib.length (lib.filter (n:
        let o = names.outputName { inherit srpm prefix; subpkg = n; }; in
        !(lib.elem o [ "out" "dev" "lib" "debug" ]) && o != names.sanitize (lib.removePrefix "${srpm}-" n)) sub.names);
    }) rpmsLock.bySrpm;
  sweepVals = lib.attrValues sweep;
  sweepFailed = lib.attrNames (lib.filterAttrs (_: v: !v.ok) sweep);
  sum = f: lib.foldl' (a: v: a + f v) 0 sweepVals;
  sweepTests = [
    (test "all lock SRPMs: outputs unique, identifiers, out first" (sweepFailed == [ ])
      ("${toString (lib.length sweepVals)} SRPMs, ${toString (sum (v: v.outputs))} outputs (incl. debug+logs), "
        + "${toString (lib.length (lib.filter (v: v.ruleless) sweepVals))} without eponymous/-libs subpackage, "
        + "${toString (sum (v: v.collisions))} collision fallbacks, "
        + "${toString (sum (v: v.refined))} non-identifier/reserved fallbacks"
        + lib.optionalString (sweepFailed != [ ]) "; FAILED: ${lib.concatStringsSep " " sweepFailed}"))
  ];

  # ---- synthetic name cases ---------------------------------------------------
  foo = extra: names.outputsFor {
    srpm = "foo";
    sub = { names = [ "foo" "foo-devel" "foo-libs" ] ++ extra; prefix = "foo"; shipped = { }; };
  };
  syn = foo [ "foo-a.b" "a-b" "dev" "foo-src" "foo-system" "foo-x" "foo-debuginfo" "foo-debugsource" "foo-C++" ];
  synTests = [
    (test "collision -> both fall back to full sanitized names"
      (syn.rpmOutputs == {
        foo = "out"; foo-devel = "foo_devel"; dev = "dev"; foo-libs = "lib";
        "foo-a.b" = "foo_a_b"; a-b = "a_b"; foo-x = "x"; "foo-C++" = "C__";
        foo-debuginfo = "debug"; foo-debugsource = "debug";
        foo-src = "foo_src"; foo-system = "foo_system";
      }) (builtins.toJSON syn.rpmOutputs))
    (test "synthetic outputs list"
      (syn.outputs == [ "out" "C__" "a_b" "dev" "foo_a_b" "foo_devel" "foo_src" "foo_system" "lib" "x" "debug" "logs" ])
      (lib.concatStringsSep " " syn.outputs))
    (test "unresolvable collision is an eval error" (throws (foo [ "foo-a.b" "foo-a-b" ])) "")
    (test "unknown merge member is an eval error"
      (throws (names.outputsFor { srpm = "foo"; sub = { names = [ "foo" "foo-x" ]; prefix = "foo"; }; mergeOutputs = [ [ "foo" "nope" ] ]; })) "")
    (test "member of two merge groups is an eval error"
      (throws (names.outputsFor { srpm = "foo"; sub = { names = [ "foo" "foo-x" "foo-y" ]; prefix = "foo"; };
        mergeOutputs = [ [ "foo" "foo-x" ] [ "foo-y" "foo-x" ] ]; })) "")
    (test "no prefix subpackage is an eval error"
      (throws (names.outputsFor { srpm = "foo"; sub = { names = [ "bar" "baz" ]; }; })) "")
    (test "debuginfo-only names add debug; merged non-prefix group takes its first member's name"
      (let r = names.outputsFor { srpm = "foo"; sub = { names = [ "foo" "foo-x" "foo-y" ]; prefix = "foo"; debug = false; };
             mergeOutputs = [ [ "foo-y" "foo-x" ] ]; };
       in r.outputs == [ "out" "y" "logs" ] && r.rpmOutputs.foo-x == "y") "")
  ];

  # ---- overrides --------------------------------------------------------------
  s1 = { name = "s1"; };
  testDir = ../tests/overrides;
  good = overrides.load { srpm = "good"; stage = s1; dir = testDir; };
  badFile = "lib/rocky/tests/overrides/bad/default.nix";
  badErrors = overrides.errors badFile (import (testDir + "/bad/default.nix") { });
  # §11.5 in S1 form, with stand-ins for stage values
  glibcExample = {
    configSite = ./names.nix;
    nixPatches = [ ./names.nix "/nix/store/x-ld-preload.patch" ];
    env = { NIX_NO_SELF_RPATH = "1"; NIX_DONT_SET_RPATH = "1"; "user-defined-trusted-dirs" = "/nix/store/x-libgcc/lib64"; };
    inputs.add = [ "/nix/store/x-kernel-headers" ];
    mergeOutputs = glibcMerge;
    runtimeSearchPaths = { "lib/locale/locale-archive" = "LOCALE_ARCHIVE";
      "lib/locale" = "LOCPATH"; "share/i18n" = "I18NPATH"; "lib64/gconv" = "GCONV_PATH"; };
    unionDirs = { "lib64" = "rtld system dir; other outputs via RUNPATH";
      "lib/locale" = "LOCPATH"; "share/locale" = "TEXTDOMAINDIR/profile"; };
    danglingOk = [ "share/zoneinfo" ];
    opaqueRefs = [ ];
    noPatchelf = [ "lib64/ld-linux-x86-64.so.2" "lib/ld-linux.so.2" "lib64/lib*.so*" "lib/lib*.so*" "x86_64-redhat-linux/sys-root/**" ];
    allowUnresolvedNeeded = [ "libgd.so.3" "libpng16.so.16" "libz.so.1" "libselinux.so.1" ];
    lateBind = { common.interpreters = [ "bash" ]; utils = { interpreters = [ "bash" "perl" ]; libs = [ "gd" "libpng" "zlib-ng" ]; };
      nss_db.libs = [ "libselinux" ]; };
    lateReferrers = { common = [ "minimal_langpack" "langpack_*" ]; nss_db = [ "nss_devel" ]; utils = [ ]; };
    fhsAllowlist = { "#!/usr/bin/bash" = "late-bound in S3"; "#!/usr/bin/sh" = "mtrace"; };
    doCheck = false;
  };
  gx = overrides.validate "packages/glibc/default.nix" glibcExample;
  bad = v: overrides.errors "packages/x/default.nix" v;
  readme = builtins.readFile (repo + "/packages/README-overrides.md");
  undocumented = lib.filter (f: !(lib.hasInfix "`${f}`" readme)) (lib.attrNames overrides.schema);

  overrideTests = [
    (test "no override file -> defaults"
      (overrides.fileFor "which" == null
        && overrides.overridesFor { stage = s1; } "which" == overrides.defaults) "")
    (test "glibc example (§11.5) validates; records filled"
      (gx.mergeOutputs == glibcMerge && gx.bconds == { "with" = [ ]; without = [ ]; }
        && gx.lateBind.nss_db == { interpreters = [ ]; libs = [ "libselinux" ]; }
        && gx.lateBind.common.libs == [ ] && gx.prefixView && gx.inputs.drop == [ ]
        && overrides.errors "packages/glibc/default.nix" glibcExample == [ ]) "")
    (test "loader: { lib, stage } file, stage-dependent values, defaults filled"
      (good.mergeOutputs == [ [ "good" "good32" ] ] && good.doCheck == false
        && good.allowUnresolvedNeeded == [ "libgd.so.3" ] && good.bconds."with" == [ ]
        && good.specSubstitutions == [ { from = "a"; to = "b"; count = 1; } ]
        && good.env."user-defined-trusted-dirs" == "/x/lib64"
        && (overrides.load { srpm = "good"; stage = { name = "s3"; }; dir = testDir; }).doCheck) "")
    (test "loader: invalid file is an eval error"
      (throws (overrides.load { srpm = "bad"; stage = s1; dir = testDir; })) "")
    (test "unknown top-level key: error names key and file"
      (hasError [ badFile "unknown key `mergeOutput`" ] badErrors) (lib.concatStringsSep " | " badErrors))
    (test "unknown nested key: error names the key path"
      (hasError [ badFile "unknown key `lateBind.common.interp`" ] badErrors) "")
    (test "type error: doCheck = \"yes\""
      (hasError [ badFile "`doCheck`: expected a bool" ] badErrors) "")
    (test "type errors: mergeOutputs, defines, specSubstitutions, env, inputs, layout"
      (hasError [ "`mergeOutputs[0]`: expected a list of a string" ] (bad { mergeOutputs = [ "glibc" ]; })
        && hasError [ "`defines.foo`: expected a single-line string" ] (bad { defines.foo = "a\nb"; })
        && hasError [ "missing required key `to`" ] (bad { specSubstitutions = [ { from = "x"; } ]; })
        && hasError [ "`specSubstitutions[0].count`: expected an int >= 1" ] (bad { specSubstitutions = [ { from = "x"; to = "y"; count = 0; } ]; })
        && hasError [ "`env.X`: expected a string, number" ] (bad { env.X = [ "a" ]; })
        && hasError [ "unknown key `inputs.remove`" ] (bad { inputs.remove = [ ]; })
        && hasError [ "`layout._datadir`: expected a string" ] (bad { layout._datadir = 1; })
        && hasError [ "the top level: expected an overrides set" ] (bad [ ])) "")
    (test "semantic errors: merges, search-path variables, lateReferrers, macro names"
      (hasError [ "needs at least 2 subpackages" ] (bad { mergeOutputs = [ [ "a" ] ]; })
        && hasError [ "`a` is in more than one group" ] (bad { mergeOutputs = [ [ "a" "b" ] [ "c" "a" ] ]; })
        && hasError [ "`runtimeSearchPaths.lib/foo`: `FOO_PATH` is not a union variable" ] (bad { runtimeSearchPaths."lib/foo" = "FOO_PATH"; })
        && hasError [ "`lateReferrers.common`: `common` is not a lateBind output" ] (bad { lateReferrers.common = [ ]; })
        && hasError [ "`defines.a-b`: not a macro name" ] (bad { defines.a-b = "1"; })) "")
    (test "validate throws on errors, returns defaults // attrs otherwise"
      (throws (overrides.validate "x" { doCheck = 1; })
        && overrides.validate "x" { } == overrides.defaults
        && (overrides.validate "x" { doCheck = true; }).doCheck) "")
    (test "packages/README-overrides.md documents every field" (undocumented == [ ])
      (lib.concatStringsSep " " undocumented))
  ];

  # ---- unions -----------------------------------------------------------------
  designVars = [ "PKG_CONFIG_PATH" "ACLOCAL_PATH" "XDG_DATA_DIRS" "GI_TYPELIB_PATH" "PERL5LIB" "PYTHONPATH"
    "MANPATH" "INFOPATH" "TERMINFO_DIRS" "GCONV_PATH" "LOCPATH" "LOCALE_ARCHIVE" "I18NPATH" "TZDIR" "NIX_DEBUG_INFO_DIRS" ];
  unionTests = [
    (test "unions: the variables of §4.1" (unions.vars == lib.sort lib.lessThan designVars) "")
    (test "unions: entries well-formed"
      (lib.all (v: let e = unions.table.${v}; in
          lib.elem e.kind [ "list" "single" ] && e.dirs != [ ] && e.sep == ":" && e.when != [ ]
          && lib.all (w: lib.elem w [ "build" "run" ]) e.when
          && lib.all (d: !(lib.hasPrefix "/" d) && !(lib.hasSuffix "/" d)) e.dirs
          && lib.attrNames e == [ "dirs" "doc" "kind" "sep" "when" ]) unions.vars
        && builtins.fromJSON unions.json == unions.table) "")
    (test "unions: forRel; glibc's search paths are union variables"
      (unions.forRel "lib/locale" == [ "LOCPATH" ] && unions.forRel "lib64/pkgconfig" == [ "PKG_CONFIG_PATH" ]
        && lib.all (v: lib.elem v unions.vars) (lib.attrValues glibcExample.runtimeSearchPaths)) "")
  ];

  results = glibcTests ++ realTests ++ sweepTests ++ synTests ++ overrideTests ++ unionTests;
  report = lib.concatMapStrings (r: "${if r.ok then "ok  " else "FAIL"}  ${r.name}${lib.optionalString (r.detail != "") "  [${r.detail}]"}\n") results;
  failed = lib.length (lib.filter (r: !r.ok) results);
in
{
  nn-names = bootPkgs.runCommandLocal "nn-names" {
    inherit report;
    profile = unions.profileScript "$root";
    passAsFile = [ "report" "profile" ];
  } ''
    cat "$reportPath"
    fail=${toString failed}

    # build-time: profileScript over a fake profile root
    root=$PWD/root
    mkdir -p $root/lib/locale/de_DE.utf8 $root/share/man $root/lib64/gconv $root/share/zoneinfo
    touch $root/lib/locale/locale-archive
    got=$(env -i root=$root MANPATH=/m TZDIR= ${bootPkgs.bash}/bin/bash -c '
      . "$1"
      echo "LOCPATH=$LOCPATH MANPATH=$MANPATH LOCALE_ARCHIVE=$LOCALE_ARCHIVE GCONV_PATH=$GCONV_PATH TZDIR=$TZDIR INFOPATH=''${INFOPATH-unset}"
    ' sh "$profilePath")
    want="LOCPATH=$root/lib/locale MANPATH=$root/share/man:/m LOCALE_ARCHIVE=$root/lib/locale/locale-archive GCONV_PATH=$root/lib64/gconv TZDIR=$root/share/zoneinfo INFOPATH=unset"
    if [ "$got" = "$want" ]; then echo "ok    unions: profileScript exports existing paths only"
    else echo "FAIL  unions: profileScript: got '$got' want '$want'"; fail=$((fail + 1)); fi

    echo "$fail failed"
    [ "$fail" = 0 ]
    cp "$reportPath" $out
  '';
}
