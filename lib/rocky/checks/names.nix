# checks.nn-names: eval-time tests of nn.names, nn.overrides and nn.unions
# (lib/rocky/{names,overrides,unions}.nix), baked into a trivial derivation.
# Every test is evaluated (a throwing test counts as failed); the build prints
# the table and fails if any test failed.  Build-time tests run
# unions.profileScript / unions.hookScript on fake roots and outputs, and
# check the locale variables end to end with a glibc (nixpkgs' `locale`).
# $out = the whole report (eval-time and build-time lines).
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
  glibcSub = names.subpackagesFor "glibc";       # the lock entry if there is one, else the fixture
  nonDebug = lib.filterAttrs (n: _: !(names.isDebugName n));
  glibcMerge = [ [ "glibc" "glibc32" ] ];
  g = names.outputsFor { srpm = "glibc"; sub = glibcSub; mergeOutputs = glibcMerge; };
  gNoMerge = names.outputsFor { srpm = "glibc"; sub = glibcSub; };
  gRevMerge = names.outputsFor { srpm = "glibc"; sub = glibcSub; mergeOutputs = [ [ "glibc32" "glibc" ] ]; };
  nOut = lib.length g.outputs;
  middle = lib.sublist 1 (nOut - 3) g.outputs;
  hasLock = names.subpackagesDoc != null;
  lockGlibc = names.subpackages.glibc or null;
  unshippedOf = e: lib.attrNames (lib.filterAttrs (_: s: !s) e.shipped);

  glibcTests = [
    (test "glibc fixture = rpms.json bySrpm.glibc + 3 unshipped"
      (lib.sort lib.lessThan fixture.names == lib.sort lib.lessThan (rpmNames "glibc" ++ glibcUnshipped)
        && lib.attrNames (lib.filterAttrs (_: s: !s) fixture.shipped) == lib.sort lib.lessThan glibcUnshipped
        && fixture.prefix == "glibc")
      "${toString (lib.length fixture.names)} subpackages, ${toString (lib.length (rpmNames "glibc"))} shipped")
    # once the lock file exists it must have a glibc entry equal to the fixture
    (test "glibc lock/subpackages.json entry = fixture"
      (!hasLock || (lockGlibc != null
        && lib.sort lib.lessThan lockGlibc.names == lib.sort lib.lessThan fixture.names
        && lockGlibc.prefix == "glibc" && unshippedOf lockGlibc == unshippedOf fixture))
      (if !hasLock then "skipped: lock/rocky-10.2/subpackages.json does not exist"
       else if lockGlibc == null then "the lock file has no glibc entry"
       else "compared: ${toString (lib.length lockGlibc.names)} names, debug ${builtins.toJSON (lockGlibc.debug or null)}"))
    (test "glibc: 224 subpackages -> 223 outputs + debug + logs"
      (lib.length (lib.filter (n: !(names.isDebugName n)) glibcSub.names) == 224 && nOut == 225)
      "${toString nOut} outputs (subpackages from ${if lockGlibc != null then "the lock" else "the fixture"})")
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
      } && lib.length (lib.attrNames (nonDebug g.rpmOutputs)) == 224
        && lib.all (o: lib.elem o g.outputs) (lib.attrValues g.rpmOutputs)
        && lib.subtractLists (lib.attrValues (nonDebug g.rpmOutputs)) g.outputs == [ "debug" "logs" ])
      "every subpackage maps to an output; every output but debug/logs has a subpackage")
    (test "glibc: unshipped flagged, 221 shipped aliases"
      (g.unshipped == { glibc32 = "out"; sysroot-x86_64-el10-glibc = "sysroot_x86_64_el10_glibc";
          compat-libpthread-nonshared = "compat_libpthread_nonshared"; }
        && lib.length (lib.attrNames (nonDebug g.shippedRpmOutputs)) == 221 && g.merged == { glibc32 = "glibc"; })
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

  # ---- other real SRPMs (name rules over their shipped subpackages) ----------
  fromRpms = srpm: args: names.outputsFor ({ inherit srpm; sub = names.fromRpms srpm; } // args);
  krb5 = fromRpms "krb5" { };
  perl = fromRpms "perl" { };
  fonts = fromRpms "xorg-x11-fonts" { prefixSubpackage = "xorg-x11-fonts-misc"; };
  realTests = [
    (test "krb5: no eponymous subpackage -> prefix krb5-libs = out"
      (krb5.prefix == "krb5-libs" && krb5.rpmOutputs.krb5-libs == "out"
        && krb5.outputs == [ "out" "dev" "libkadm5" "pkinit" "server" "server_ldap" "workstation" "xrealmauthz" "debug" "logs" ])
      (lib.concatStringsSep " " krb5.outputs))
    (test "krb5: prefixSubpackage override; -libs then becomes lib"
      (let k = fromRpms "krb5" { prefixSubpackage = "krb5-workstation"; };
       in k.rpmOutputs.krb5-workstation == "out" && k.rpmOutputs.krb5-libs == "lib") "")
    (test "perl: perl-lib / perl-libs collide on `lib` -> full names"
      (perl.rpmOutputs.perl-lib == "perl_lib" && perl.rpmOutputs.perl-libs == "perl_libs"
        && perl.rpmOutputs.perl-devel == "dev") "")
    (test "xorg-x11-fonts: 100dpi is not an identifier -> full name"
      (fonts.rpmOutputs.xorg-x11-fonts-100dpi == "xorg_x11_fonts_100dpi"
        && fonts.rpmOutputs.xorg-x11-fonts-Type1 == "Type1") "")
  ];

  # ---- subpackages.json: format of tools/lock_subpackages.py ------------------
  # every entry of the lock file (when there is one) gives valid outputs
  lockSweep = lib.mapAttrs (srpm: e:
    let r = builtins.tryEval (let o = names.outputsFor { inherit srpm; sub = e; }; in builtins.deepSeq o o);
    in r.success && lib.head r.value.outputs == "out" && allUnique r.value.outputs
      && lib.all names.isIdentifier r.value.outputs
      && lib.elem "debug" r.value.outputs == (e.debug or [ ] != [ ])) names.subpackages;
  lockBad = lib.attrNames (lib.filterAttrs (_: ok: !ok) lockSweep);
  # a bash entry exactly as the lock generator writes it
  bashEntry = { debug = [ "bash-debuginfo" "bash-debugsource" ]; evr = "5.2.26-6.el10";
    names = [ "bash" "bash-devel" "bash-doc" ]; noarch = [ ]; prefix = "bash"; prefixRule = "eponymous";
    shipped = { bash = true; bash-devel = true; bash-doc = false; }; };
  bashO = names.outputsFor { srpm = "bash"; sub = bashEntry; };
  noDebug = names.outputsFor { srpm = "m"; sub = { names = [ "m" "m-x" ]; prefix = "m"; debug = [ ]; shipped = { }; }; };
  missingSrpm = "nn-names-no-such-srpm";
  lockFormatTests = [
    (test "subpackages.json: every lock entry gives valid outputs (debug iff debug packages)" (lockBad == [ ])
      (if !hasLock then "skipped: no lock file"
       else "${toString (lib.length (lib.attrNames lockSweep))} entries, coverage ${builtins.toJSON (names.subpackagesDoc.coverage or null)}"
         + lib.optionalString (lockBad != [ ]) "; FAILED: ${lib.concatStringsSep " " lockBad}"))
    (test "subpackages.json entry format: debug list, shipped = false -> unshipped"
      (bashO.outputs == [ "out" "dev" "doc" "debug" "logs" ]
        && bashO.rpmOutputs == { bash = "out"; bash-devel = "dev"; bash-doc = "doc";
             bash-debuginfo = "debug"; bash-debugsource = "debug"; }
        && bashO.unshipped == { bash-doc = "doc"; }
        && bashO.shippedRpmOutputs == removeAttrs bashO.rpmOutputs [ "bash-doc" ])
      (builtins.toJSON bashO.outputs))
    (test "subpackages.json entry format: debug = [ ] -> no debug output; bad debug fields are errors"
      (noDebug.outputs == [ "out" "x" "logs" ]
        && throws (names.outputsFor { srpm = "m"; sub = { names = [ "m" ]; prefix = "m"; debug = "yes"; }; })
        && throws (names.outputsFor { srpm = "m"; sub = { names = [ "m" ]; prefix = "m"; debug = [ "m-x" ]; }; })
        && names.isDebugName "kernel-debuginfo-common-x86_64") "")
    (test "subpackagesFor: no lock entry and no fixture is an eval error, never a guess"
      (throws (names.subpackagesFor missingSrpm) && throws (names.outputsForSrpm { srpm = missingSrpm; })
        && (names.subpackagesOrRpms missingSrpm).fromRpms
        && (names.subpackagesOrRpms "glibc") == glibcSub) "")
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
  testDir = ../tests/names-overrides;
  good = overrides.load { srpm = "good"; stage = s1; dir = testDir; };
  badFile = "lib/rocky/tests/names-overrides/bad/default.nix";
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
        && hasError [ "`layout._datadir`: expected an output name" ] (bad { layout._datadir = 1; })
        && hasError [ "the top level: expected an overrides set" ] (bad [ ])) "")
    (test "semantic errors: merges, search-path variables, lateReferrers, macro names"
      (hasError [ "needs at least 2 subpackages" ] (bad { mergeOutputs = [ [ "a" ] ]; })
        && hasError [ "`a` is in more than one group" ] (bad { mergeOutputs = [ [ "a" "b" ] [ "c" "a" ] ]; })
        && hasError [ "`runtimeSearchPaths.lib/foo`: `FOO_PATH` is not a union variable" ] (bad { runtimeSearchPaths."lib/foo" = "FOO_PATH"; })
        && hasError [ "`lateReferrers.common`: `common` is not a lateBind output" ] (bad { lateReferrers.common = [ ]; })
        && hasError [ "`defines.a-b`: not a macro name" ] (bad { defines.a-b = "1"; })) "")
    (test "function-valued fields: an error naming file and key, not a hard failure"
      (let r = builtins.tryEval (builtins.deepSeq (bad { doCheck = x: true; }) (bad { doCheck = x: true; }));
       in r.success
        && hasError [ "packages/x/default.nix: `doCheck`: expected a bool, got a function" ] r.value
        && hasError [ "`allowUnresolvedNeeded`: expected a list of a string, got a function" ]
             (bad { allowUnresolvedNeeded = lib.optionals true; })
        && hasError [ "`env.X`: expected a string" ] (bad { env.X = x: x; })
        && hasError [ "the top level: expected an overrides set, got a function" ] (bad ({ lib }: { }))) "")
    (test "shape errors: output names, output-relative paths, empty `from`"
      (hasError [ "`layout._datadir`: expected an output name" ] (bad { layout._datadir = "not an output!"; })
        && hasError [ "`lateBind.not-an-output`: `not-an-output` is not an output name" ] (bad { lateBind."not-an-output" = { }; })
        && hasError [ "`lateReferrers.common[0]`: expected an output name or a glob" ]
             (bad { lateBind.common = { }; lateReferrers.common = [ "no such output" ]; })
        && bad { lateBind.common = { }; lateReferrers.common = [ "langpack_*" "minimal_langpack" "x[!a]?" ]; } == [ ]
        && hasError [ "`runtimeSearchPaths./usr/lib/locale`: `/usr/lib/locale` is not an output-relative path" ]
             (bad { runtimeSearchPaths."/usr/lib/locale" = "LOCPATH"; })
        && hasError [ "`unionDirs.lib/../x`: `lib/../x` is not an output-relative path" ] (bad { unionDirs."lib/../x" = "y"; })
        && hasError [ "`danglingOk[0]`: expected an output-relative path" ] (bad { danglingOk = [ "/usr/share/zoneinfo" ]; })
        && hasError [ "`noPatchelf[0]`: expected an output-relative glob" ] (bad { noPatchelf = [ "/lib64/*" ]; })
        && hasError [ "`specSubstitutions[0].from`: expected a non-empty string" ] (bad { specSubstitutions = [ { from = ""; to = "x"; } ]; }))
      "")
    (test "outputErrors / checkOutputs: output names checked against outputsFor"
      (overrides.outputErrors "packages/glibc/default.nix" gx g == [ ]
        && overrides.checkOutputs "p" gx g == gx
        && (let es = overrides.outputErrors "p" (gx // { layout._datadir = "nope"; lateBind = gx.lateBind // { zz = { }; };
                  lateReferrers = gx.lateReferrers // { zz = [ "zzz_*" ]; }; }) g;
            in hasError [ "p: `layout._datadir`: `nope` is not an output" ] es
              && hasError [ "`lateBind.zz`: `zz` is not an output" ] es
              && hasError [ "`lateReferrers.zz`: `zzz_*` matches no output" ] es)
        && throws (overrides.checkOutputs "p" (gx // { layout._datadir = "nope"; }) g)) "")
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
          && (e.provider == null || builtins.isString e.provider)
          && lib.all (y: unions.table ? ${y} && unions.table.${y}.provider == null && y != v) e.yieldsTo
          && lib.attrNames e == [ "dirs" "doc" "kind" "provider" "sep" "when" "yieldsTo" ]) unions.vars
        && builtins.fromJSON unions.json == unions.table) "")
    (test "unions: forRel; glibc's search paths are union variables"
      (unions.forRel "lib/locale" == [ "LOCPATH" ] && unions.forRel "lib64/pkgconfig" == [ "PKG_CONFIG_PATH" ]
        && lib.all (v: lib.elem v unions.vars) (lib.attrValues glibcExample.runtimeSearchPaths)) "")
    (test "unions: LOCPATH needs directory locales and yields to LOCALE_ARCHIVE; I18NPATH at run time"
      (unions.table.LOCPATH.provider == "*/LC_CTYPE" && unions.yielders "LOCALE_ARCHIVE" == [ "LOCPATH" ]
        && unions.table.I18NPATH.when == [ "build" "run" ]) "")
  ];

  results = glibcTests ++ realTests ++ lockFormatTests ++ sweepTests ++ synTests ++ overrideTests ++ unionTests;
  report = lib.concatMapStrings (r: "${if r.ok then "ok  " else "FAIL"}  ${r.name}${lib.optionalString (r.detail != "") "  [${r.detail}]"}\n") results;
  failed = lib.length (lib.filter (r: !r.ok) results);

  # nixpkgs' glibc: `locale` honours LOCPATH and LOCALE_ARCHIVE like Rocky's
  # glibc with P2 (findlocale.c: the archive is read only when LOCPATH is unset)
  glibcBin = bootPkgs.glibc.bin;
in
{
  nn-names = bootPkgs.runCommandLocal "nn-names" {
    inherit report;
    profile = unions.profileScript "$root";
    hook = unions.hookScript "$o";
    passAsFile = [ "report" "profile" "hook" ];
  } ''
    cp "$reportPath" res
    fail=${toString failed}
    check() { # name got want
      if [ "$2" = "$3" ]; then echo "ok    $1" >> res
      else echo "FAIL  $1: got '$2' want '$3'" >> res; fail=$((fail + 1)); fi
    }
    vars='LOCPATH=''${LOCPATH-unset} LOCALE_ARCHIVE=''${LOCALE_ARCHIVE-unset}'

    # ---- profileScript over fake profile roots ------------------------------
    mkroot() { # dir what...
      local r=$1; shift
      mkdir -p $r/share/man $r/lib64/gconv $r/share/zoneinfo $r/lib/locale
      for w; do case $w in
        dirs) mkdir -p $r/lib/locale/de_DE.utf8; touch $r/lib/locale/de_DE.utf8/LC_CTYPE ;;
        archive) touch $r/lib/locale/locale-archive ;;
      esac; done
    }
    profile() { # root -> the variables after sourcing the profile
      env -i root=$1 MANPATH=/m TZDIR= LOCPATH=/stale ${bootPkgs.bash}/bin/bash -c '
        . "$1"; echo "MANPATH=$MANPATH GCONV_PATH=$GCONV_PATH TZDIR=$TZDIR INFOPATH=''${INFOPATH-unset} '"$vars"'"
      ' sh "$profilePath"
    }
    common="MANPATH=$PWD/@/share/man:/m GCONV_PATH=$PWD/@/lib64/gconv TZDIR=$PWD/@/share/zoneinfo INFOPATH=unset"
    mkroot $PWD/r-dirs dirs
    mkroot $PWD/r-archive archive
    mkroot $PWD/r-both dirs archive
    mkroot $PWD/r-none
    check "unions: profileScript, langpack root -> LOCPATH" "$(profile $PWD/r-dirs)" \
      "''${common//@/r-dirs} LOCPATH=$PWD/r-dirs/lib/locale:/stale LOCALE_ARCHIVE=unset"
    check "unions: profileScript, archive-only root -> LOCALE_ARCHIVE, LOCPATH unset" "$(profile $PWD/r-archive)" \
      "''${common//@/r-archive} LOCPATH=unset LOCALE_ARCHIVE=$PWD/r-archive/lib/locale/locale-archive"
    check "unions: profileScript, archive + langpack root -> LOCALE_ARCHIVE only" "$(profile $PWD/r-both)" \
      "''${common//@/r-both} LOCPATH=unset LOCALE_ARCHIVE=$PWD/r-both/lib/locale/locale-archive"
    check "unions: profileScript, empty lib/locale -> neither" "$(profile $PWD/r-none)" \
      "''${common//@/r-none} LOCPATH=/stale LOCALE_ARCHIVE=unset"

    # ---- hookScript over fake outputs, both orders ---------------------------
    mkdir -p o-lang/lib/locale/de_DE.utf8 o-all/lib/locale o-dev/lib64/pkgconfig o-dev/share/pkgconfig
    touch o-lang/lib/locale/de_DE.utf8/LC_CTYPE o-all/lib/locale/locale-archive
    hooks() { # outputs... -> the variables after sourcing their hooks in order
      env -i hook=$hookPath ${bootPkgs.bash}/bin/bash -c '
        addToSearchPath() { # setup.sh semantics (existing dirs, appended)
          [ -d "$2" ] || return 0; export "$1=''${!1:+''${!1}:}$2"; }
        for o; do . "$hook"; done
        echo "PKG_CONFIG_PATH=''${PKG_CONFIG_PATH-unset} '"$vars"'"
      ' sh "$@"
    }
    check "unions: hookScript, langpack output -> LOCPATH" "$(hooks $PWD/o-lang)" \
      "PKG_CONFIG_PATH=unset LOCPATH=$PWD/o-lang/lib/locale LOCALE_ARCHIVE=unset"
    check "unions: hookScript, langpack then all_langpacks -> LOCALE_ARCHIVE only" "$(hooks $PWD/o-lang $PWD/o-all)" \
      "PKG_CONFIG_PATH=unset LOCPATH=unset LOCALE_ARCHIVE=$PWD/o-all/lib/locale/locale-archive"
    check "unions: hookScript, all_langpacks then langpack -> LOCALE_ARCHIVE only" "$(hooks $PWD/o-all $PWD/o-lang)" \
      "PKG_CONFIG_PATH=unset LOCPATH=unset LOCALE_ARCHIVE=$PWD/o-all/lib/locale/locale-archive"
    check "unions: hookScript, lib64 before share pkgconfig" "$(hooks $PWD/o-dev)" \
      "PKG_CONFIG_PATH=$PWD/o-dev/lib64/pkgconfig:$PWD/o-dev/share/pkgconfig LOCPATH=unset LOCALE_ARCHIVE=unset"

    # ---- end to end with a real glibc ----------------------------------------
    # a root like all_langpacks + a langpack (archive with en_US, de_DE as a dir)
    export I18NPATH=${bootPkgs.glibc}/share/i18n
    mkdir -p g/${bootPkgs.glibc}/lib/locale e2e/lib/locale
    ${glibcBin}/bin/localedef --prefix=$PWD/g -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true
    mv g/${bootPkgs.glibc}/lib/locale/locale-archive e2e/lib/locale/
    ${glibcBin}/bin/localedef --no-archive -i de_DE -f UTF-8 e2e/lib/locale/de_DE.UTF-8 2>/dev/null || true
    abday() { # root LC_ALL [extra env] -> abday of LC_ALL with the profile's variables
      env -i root=$1 lc=$2 extra="''${3-}" ${bootPkgs.bash}/bin/bash -c '
        . "$1"; [ -z "$extra" ] || export "$extra"
        LC_ALL=$lc ${glibcBin}/bin/locale -k abday 2>&1
      ' sh "$profilePath" | head -1
    }
    check "glibc: archive + langpack profile -> en_US from the archive" "$(abday $PWD/e2e en_US.UTF-8)" \
      'abday="Sun;Mon;Tue;Wed;Thu;Fri;Sat"'
    check "glibc: (control) LOCPATH set as well -> the archive is ignored" \
      "$(abday $PWD/e2e en_US.UTF-8 LOCPATH=$PWD/e2e/lib/locale | grep -c 'Cannot set LC_CTYPE')" 1
    rm e2e/lib/locale/locale-archive
    check "glibc: langpack-only profile -> de_DE via LOCPATH" "$(abday $PWD/e2e de_DE.UTF-8)" \
      'abday="So;Mo;Di;Mi;Do;Fr;Sa"'

    echo "$fail failed" >> res
    cat res
    [ "$fail" = 0 ]
    cp res $out
  '';
}
