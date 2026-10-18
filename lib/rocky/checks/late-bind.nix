# checks.nn-late-bind: lateBind.wrap (lib/rocky/late-bind.nix, design §2.9,
# §11.3, WP11) on a synthetic multi-output derivation shaped like glibc:
#   out          share/nn/greeting (referenced by common; not late, stays raw)
#   common       late (interpreters = dummy bash): #!/usr/bin/bash, #!/usr/bin/env
#                bash and #!/bin/sh scripts, lib/locale/C.utf8, an ELF without
#                late references
#   langpack_00..19  referrers: lib/locale/<xx>/LC_CTYPE -> $common/.../C.utf8;
#                langpack_00 also has a text file naming common; langpack_19
#                reaches common only through langpack_00 (transitive referrer)
#   utils        late (interpreters = dummy bash, libs = libfoo): bin/use-foo NEEDs
#                libfoo.so.1 from another derivation, no RUNPATH (unresolved, as
#                memusagestat in S1); a bash script running it
#   dev          references out only (untouched)
#   debug        references common and utils (skipped: neither bound nor an error)
# Build-time assertions: the bound closure holds no raw L* output (raw out and
# the dummy bash / libfoo are there); every langpack symlink resolves into the
# bound common; the scripts run through the dummy bash; use-foo runs (and the
# raw one does not: control); no store path in the bind reports.
# Eval-time assertions: result shape, untouched outputs, wrap argument errors,
# fromOverrides/missing.
#
# checks.nn-late-bind-unit: lib/rocky/late-bind/tests/unit.py, the builder on
# synthetic trees in a fake store: rebinding, incomplete referrers (direct and
# transitive), ELF-content refusal (late output and referrer), RUNPATH rebinding,
# compressed / hidden references, NEEDED binding (unused lib, strict system dirs),
# shebangs, name mismatch, incomplete graph, skip.
{ bootPkgs, lib, self, ... }:
let
  pkgs = bootPkgs;
  lb = self.lateBind;
  langs = map (i: "langpack_${lib.fixedWidthNumber 2 i}") (lib.range 0 19);

  libfoo = pkgs.runCommandCC "nn-late-libfoo-1.0" { dontMoveLib64 = true; } ''
    mkdir -p $out/lib64
    printf '#include <stdio.h>\nvoid foo(void){puts("libfoo-ok");}\n' > foo.c
    cc -shared -fPIC -Wl,-soname,libfoo.so.1 -o $out/lib64/libfoo.so.1 foo.c
    ln -s libfoo.so.1 $out/lib64/libfoo.so
  '';

  dummyBash = pkgs.runCommand "nn-late-dummy-bash" { } ''
    mkdir -p $out/bin
    { echo '#!${pkgs.bash}/bin/bash'
      echo "export NN_DUMMY_BASH=$out"
      echo 'exec ${pkgs.bash}/bin/bash "$@"'; } > $out/bin/bash
    chmod +x $out/bin/bash
  '';

  raw = pkgs.stdenv.mkDerivation {
    pname = "nn-late-raw";
    version = "1.0";
    outputs = [ "out" "dev" "common" "utils" "debug" ] ++ langs;
    dontUnpack = true;
    dontPatchShebangs = true; dontPatchELF = true; dontStrip = true; dontMoveLib64 = true;
    NIX_NO_SELF_RPATH = "1";
    buildPhase = ''
      printf '#include <stdio.h>\nint main(void){puts("common-elf");return 0;}\n' > common.c
      cc -o common-elf common.c
      printf 'void foo(void);\nint main(void){foo();return 0;}\n' > use.c
      cc -o use-foo use.c -L${libfoo}/lib64 -lfoo
      patchelf --remove-rpath use-foo
    '';
    installPhase = ''
      mkdir -p $out/share/nn $dev/include $debug/lib/debug
      echo greeting-from-out > $out/share/nn/greeting
      echo '#define NN "'$out'"' > $dev/include/nn.h

      mkdir -p $common/bin $common/share/nn $common/lib/locale/C.utf8
      echo common-data > $common/share/nn/data
      echo C.utf8-LC_CTYPE > $common/lib/locale/C.utf8/LC_CTYPE
      echo C.utf8-LC_NUMERIC > $common/lib/locale/C.utf8/LC_NUMERIC
      { echo '#!/usr/bin/bash'
        echo 'echo "ldd bash=''${NN_DUMMY_BASH:-none} $(cat '$common'/share/nn/data) $(cat '$out'/share/nn/greeting)"'
      } > $common/bin/ldd
      printf '#!/usr/bin/env bash\necho "env bash=''${NN_DUMMY_BASH:-none}"\n' > $common/bin/tzselect
      printf '#!/bin/sh\necho plain-sh\n' > $common/bin/plain-sh
      chmod +x $common/bin/*
      install -m755 common-elf $common/bin/common-elf

      mkdir -p $utils/bin
      install -m755 use-foo $utils/bin/use-foo
      { echo '#!/usr/bin/bash'
        echo 'echo "memusage bash=''${NN_DUMMY_BASH:-none}"; exec '$utils'/bin/use-foo'
      } > $utils/bin/memusage
      chmod +x $utils/bin/memusage

      for o in ${lib.concatStringsSep " " langs}; do
        d=''${!o}/lib/locale/''${o#langpack_}_XX.UTF-8
        mkdir -p $d/LC_MESSAGES
        echo "$o messages" > $d/LC_MESSAGES/SYS_LC_MESSAGES
        if [ $o = langpack_19 ]; then
          ln -s $langpack_00/lib/locale/00_XX.UTF-8/LC_CTYPE $d/LC_CTYPE
        else
          ln -s $common/lib/locale/C.utf8/LC_CTYPE $d/LC_CTYPE
        fi
      done
      mkdir -p $langpack_00/share/nn
      echo "C.utf8 lives in $common/lib/locale/C.utf8" > $langpack_00/share/nn/where
      echo "debug info for $common $utils" > $debug/lib/debug/nn.debug
    '';
  };

  args = {
    binds = {
      common.interpreters = [ dummyBash ];
      utils = { interpreters = [ dummyBash ]; libs = [ libfoo ]; };
    };
    referrers.common = [ "langpack_*" ];
    systemLibDirs = [ "${pkgs.stdenv.cc.libc}/lib" ];
  };
  result = lb.wrap raw args;
  lstar = [ "common" "utils" ] ++ langs;

  # ---- eval-time tests
  fails = e: !(builtins.tryEval (builtins.deepSeq e e)).success;
  ovFixture = {
    lateBind = { common.interpreters = [ "bash" ]; utils = { interpreters = [ "bash" ]; libs = [ "libfoo" ]; }; };
    lateReferrers.common = [ "langpack_*" ];
  };
  fromOv = lb.fromOverrides { pkgs = { bash = dummyBash; libfoo = libfoo; }; } ovFixture;
  tests = {
    "bound output differs from raw" = result.common.outPath != raw.common.outPath;
    "bound output is the bind derivation's" = result.common.outPath == result.bound.common.outPath;
    "langpack bound" = result.langpack_07.outPath == result.bound.langpack_07.outPath;
    "untouched output is raw" = result.dev.outPath == raw.dev.outPath && result.outPath == raw.outPath;
    "debug is raw (skip)" = result.debug.outPath == raw.debug.outPath;
    "outputs of untouched outputs see bound ones" = result.dev.common.outPath == result.common.outPath;
    "outputs see bound siblings" = result.langpack_00.utils.outPath == result.utils.outPath;
    "raw kept" = result.raw.common.outPath == raw.common.outPath;
    "lateBound = L*" = lib.sort lib.lessThan result.lateBound == lib.sort lib.lessThan lstar;
    "late = binds" = result.late == [ "common" "utils" ];
    "bound outputs = summary out + L* in raw order" =
      result.bound.outputs == [ "out" ] ++ lib.filter (o: lib.elem o lstar) raw.outputs;
    "all follows" = map (d: d.outPath) result.all == map (o: result.${o}.outPath) raw.outputs;
    "outputName kept" = result.common.outputName == "common" && result.outputName == "out";
    "same store name" = builtins.substring 33 100 (baseNameOf result.common.outPath)
      == builtins.substring 33 100 (baseNameOf raw.common.outPath);
    "binds = {} returns raw" = (lb.wrap raw { binds = { }; }).outPath == raw.outPath;
    "error: bind of a non-output" = fails (lb.wrap raw { binds.nope.libs = [ ]; }).outPath;
    "error: bind of a skip output" = fails (lb.wrap raw { binds.debug.libs = [ ]; }).outPath;
    "error: unknown bind key" = fails (lb.wrap raw { binds.common.interp = [ ]; }).outPath;
    "error: referrer key not bound" = fails (lb.wrap raw { binds.common = { }; referrers.utils = [ "dev" ]; }).outPath;
    "error: referrer glob matches nothing" =
      fails (lb.wrap raw { binds.common = { }; referrers.common = [ "langpack_x*" ]; }).outPath;
    "error: referrer is a skip output" =
      fails (lb.wrap raw { binds.common = { }; referrers.common = [ "debug" ]; }).outPath;
    "glob does not pick skip outputs" =
      (lb.wrap raw { binds.common = { }; referrers.common = [ "*" ]; }).debug.outPath == raw.debug.outPath;
    "fromOverrides resolves names" =
      fromOv.binds.utils.libs == [ libfoo ] && fromOv.binds.common.interpreters == [ dummyBash ]
      && fromOv.referrers == ovFixture.lateReferrers;
    "fromOverrides: python3 -> python3.12" =
      (lb.fromOverrides { pkgs = { "python3.12" = dummyBash; }; } { lateBind.x.interpreters = [ "python3" ]; })
        .binds.x.interpreters == [ dummyBash ];
    "fromOverrides throws on missing names" = fails (lb.fromOverrides { pkgs = { }; } ovFixture);
    "missing lists names" = lb.missing { pkgs = { bash = dummyBash; }; } ovFixture == [ "lateBind.utils.libs: libfoo" ];
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) tests);
in
{
  nn-late-bind = pkgs.runCommand "nn-late-bind" {
    __structuredAttrs = true;
    nativeBuildInputs = [ pkgs.python3 pkgs.binutils-unwrapped pkgs.gnugrep ];
    evalFailed = failed;
    evalCount = lib.length (lib.attrNames tests);
    bound = map (o: result.${o}) lstar;
    rawLstar = map (o: raw.${o}) lstar;
    rawOut = raw.out;
    summary = result.bound.out;
    inherit dummyBash libfoo;
    exportReferencesGraph.closure = map (o: result.${o}) lstar;
    passthru = {
      inherit raw result libfoo dummyBash;
      # manual negative controls (each must FAIL to build):
      #   nix build .#checks.x86_64-linux.nn-late-bind.negative.noReferrers   (late-referrer-missing)
      #   nix build .#checks.x86_64-linux.nn-late-bind.negative.noInterpreter (late-shebang-unbound)
      negative = {
        noReferrers = (lb.wrap raw (args // { referrers = { }; })).bound;
        noInterpreter = (lb.wrap raw (args // { binds = args.binds // { common = { }; }; })).bound;
      };
    };
  } ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    ok() { echo "ok: $*"; }
    if [ ''${#evalFailed[@]} -gt 0 ]; then
      printf 'FAIL (eval): %s\n' "''${evalFailed[@]}" >&2; exit 1
    fi
    ok "$evalCount eval-time tests"

    # --- closure: no raw L* output; raw out, dummy bash, libfoo present
    python3 -I - "$NIX_ATTRS_JSON_FILE" <<'PY'
    import json, sys
    a = json.load(open(sys.argv[1]))
    closure = {e["path"] for e in a["closure"]}
    bad = sorted(set(a["rawLstar"]) & closure)
    assert not bad, "raw L* outputs in the bound closure: %s" % bad
    for k in ("rawOut", "dummyBash", "libfoo"):
        assert a[k] in closure, "%s missing from the closure" % k
    assert set(a["bound"]) <= closure
    print("ok: bound closure (%d paths) holds no raw L* output; raw out, dummy bash, libfoo present" % len(closure))
    PY

    declare -A B
    for p in "''${bound[@]}"; do o=''${p##*-nn-late-raw-1.0-}; B[$o]=$p; done
    common=''${B[common]} utils=''${B[utils]}

    # --- symlinks resolve into the bound common
    n=0
    for o in "''${!B[@]}"; do
      case $o in langpack_*) ;; *) continue ;; esac
      l=''${B[$o]}/lib/locale/''${o#langpack_}_XX.UTF-8/LC_CTYPE
      t=$(readlink -e "$l") || fail "$o: LC_CTYPE dangles"
      [ "$t" = "$common/lib/locale/C.utf8/LC_CTYPE" ] || fail "$o: LC_CTYPE -> $t, not the bound common"
      [ "$(cat "$l")" = C.utf8-LC_CTYPE ] || fail "$o: content"
      n=$((n+1))
    done
    [ $n = 20 ] || fail "expected 20 langpacks, saw $n"
    case $(readlink ''${B[langpack_19]}/lib/locale/19_XX.UTF-8/LC_CTYPE) in
      ''${B[langpack_00]}/*) ;; *) fail "langpack_19 does not point at the bound langpack_00" ;; esac
    grep -qx "C.utf8 lives in $common/lib/locale/C.utf8" ''${B[langpack_00]}/share/nn/where || fail "text not rebound"
    ok "20 langpack symlinks resolve into the bound common (19 via 00); text rebound"

    # --- scripts run through the dummy bash
    test ! -e /usr/bin/bash || fail "/usr/bin/bash exists in the sandbox (control is void)"
    [ "$(head -1 $common/bin/ldd)" = "#!$dummyBash/bin/bash" ] || fail "ldd shebang: $(head -1 $common/bin/ldd)"
    out=$($common/bin/ldd)
    [ "$out" = "ldd bash=$dummyBash common-data greeting-from-out" ] || fail "ldd printed: $out"
    [ "$($common/bin/tzselect)" = "env bash=$dummyBash" ] || fail "tzselect (#!/usr/bin/env bash)"
    [ "$(head -1 $common/bin/plain-sh)" = "#!/bin/sh" ] || fail "#!/bin/sh was changed"
    [ "$($common/bin/plain-sh)" = plain-sh ] || fail "plain-sh"
    [ "$($common/bin/common-elf)" = common-elf ] || fail "common-elf"
    if ''${rawLstar[0]}/bin/ldd 2>/dev/null; then fail "raw ldd ran (control)"; fi
    ok "scripts run through the dummy bash; #!/bin/sh kept; raw script does not run (control)"

    # --- ELF runs with libfoo bound
    readelf -d $utils/bin/use-foo | grep -q "RUNPATH.*$libfoo/lib64" || fail "use-foo RUNPATH lacks libfoo"
    [ "$($utils/bin/use-foo)" = libfoo-ok ] || fail "bound use-foo"
    [ "$($utils/bin/memusage)" = "memusage bash=$dummyBash
    libfoo-ok" ] || fail "memusage: $($utils/bin/memusage)"
    if ''${rawLstar[1]}/bin/use-foo 2>/dev/null; then fail "raw use-foo ran (control)"; fi
    ok "bound use-foo runs (RUNPATH $libfoo/lib64); raw use-foo does not (control)"

    # --- reports
    for o in common utils langpack_00; do
      f=''${B[$o]}/nix-support/rocky-late-bind.json
      test -f $f || fail "$o: no rocky-late-bind.json"
      if grep -q /nix/store $f; then fail "$o: store path in the report"; fi
    done
    grep -q '"langpack_19"' $common/nix-support/rocky-late-bind.json || fail "common report lacks referrers"
    test -f $summary/nix-support/rocky-late-bind.json || fail "no summary in the bind derivation's out"
    if grep -q /nix/store $summary/nix-support/rocky-late-bind.json; then fail "store path in the summary"; fi
    ok "reports present, no store paths"
    echo passed > "''${outputs[out]}"
  '';

  nn-late-bind-unit = pkgs.runCommandCC "nn-late-bind-unit" {
    nativeBuildInputs = [ pkgs.python3 pkgs.patchelf ];
  } ''
    set -o pipefail
    export -f patchShebangs isScript
    python3 -I ${../late-bind/tests/unit.py} --tool ${lb.tool} --elf-lib ${self.partitionTool} \
      --workdir $TMPDIR/unit | tee $TMPDIR/log
    mkdir -p $out; cp $TMPDIR/log $out/log
  '';
}
