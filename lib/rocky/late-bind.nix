# lateBind: the bind derivation (docs/nix-native-design.md §2.9, §11.3).
#
# A raw rocky.<srpm> output that needs a package built later (glibc `common`
# and `utils`: #!/usr/bin/bash, memusagestat NEEDs libgd) is shipped as a
# *bound* copy: one cheap derivation whose outputs are
#     L* = L (the late outputs, keys of `binds`) ∪ their declared referrers
# (sibling outputs that reference L, transitively: langpacks -> common).
# The builder (lib/rocky/late-bind/late-bind.py) copies raw.<o> -> $o and
#   * rewrites raw L* hashes -> bound hashes in symlink targets and in every
#     non-ELF file (equal length: the bound derivation has raw's name, so the
#     store names match);
#   * RUNPATH: raw L* entries -> bound, plus the lib dirs of `binds.<o>.libs`
#     that resolve a DT_NEEDED the raw RUNPATH left unresolved (patchelf);
#   * refuses ELF / ar contents and compressed members that hold a raw L*
#     hash outside DT_RUNPATH (never rewritten: store-by-pieces, §0.2 #1),
#     and nix-support/hidden-references naming a raw L* output;
#   * verifies `referrers` against the raw outputs' registered references
#     (exportReferencesGraph): an output reaching L that is not in L* is an
#     error, since it would keep raw L in the closure;
#   * runs nixpkgs patchShebangs --host per late output against the given
#     interpreters, then checks that no late output keeps an FHS shebang except
#     #!/bin/sh and #!/usr/bin/env (runtime FHS) in an executable, and that no
#     raw L* hash is left anywhere (referrers' shebangs are left as they are);
#   * Nix enforces it too: outputChecks.<o>.disallowedRequisites = raw L*.
#
# Interface (nn.lateBind):
#   wrap raw { binds; referrers ? { }; systemLibDirs ? [ ]; skip ? [ "debug" "logs" ]; }
#     binds      { <late output> = { interpreters ? [ drv ]; libs ? [ drv ]; }; }
#                interpreters: packages whose bin/ (lib.getBin) provides the
#                shebang interpreters; libs: packages whose lib64/ and lib/
#                provide the unresolved DT_NEEDED (lib.getLib first, then the
#                package's other outputs except debug/logs; an output passed
#                directly is the only candidate); only dirs that resolve a
#                soname enter the RUNPATH, so only those become references
#     referrers  { <late output> = [ output name or glob ]; }  (= overrides.lateReferrers)
#     systemLibDirs  when non-empty, every DT_NEEDED of an ELF in an output with
#                libs must resolve (old RUNPATH, these dirs, the libs); else the
#                rest is left to the loader (reported)
#     skip       raw outputs that are neither bound nor checked (debug may
#                reference siblings and is not rebound, design §7.1 / R7)
#     passthruFor result o   extra attributes of output attribute `o` (and of
#                the top level, o = raw's outputName); `result` = { <o> = the
#                final output attribute }.  mkRpmPackage puts the per-output
#                rockyRequisites / rockyOutputsByName of the bound package here
#     checkBound d   applied to the bind derivation (mkRpmPackage: the stage's
#                purity check)
#   -> raw // { <o> = bound <o> for o in L*; raw; bound; lateBound = L*; late = L; }
#      Every output attribute (also those of untouched outputs, e.g.
#      result.dev.common) points at the bound outputs; `all` and `outputs`
#      are those of raw.  binds = { } returns raw unchanged.  `bound` is the bind
#      derivation; unless `out` is in L* its `out` is an extra output holding
#      only nix-support/rocky-late-bind.json (the summary, no store paths).
#   fromOverrides { pkgs; interpreterPkgs ? { }; } overrides
#     -> { binds; referrers; } from overrides.lateBind / lateReferrers: libs are
#        SRPM names (pkgs.<srpm>), interpreters are shebang basenames
#        (interpreterPkgs.<name>, else pkgs.<interpreterSrpm.<name> or name>);
#        throws listing every name it cannot resolve
#   missing { pkgs; interpreterPkgs ? { }; } overrides -> [ name ] (unresolvable)
#   mk { stdenvNoCC, patchelf, python3, partitionTool } -> the same set over other
#     build tools (S3: the stage's); the default uses bootPkgs (build tooling
#     only: no shipped output references the builder).
{ lib, bootPkgs, partitionTool }:
let
  mk = { stdenvNoCC, patchelf, python3, partitionTool }:
    let
      tool = ./late-bind/late-bind.py;

      globRegex = g: builtins.replaceStrings [ "." "+" "*" "?" "[!" ] [ "\\." "\\+" ".*" "." "[^" ] g;
      isGlob = g: builtins.match ".*[][*?].*" g != null;

      wrap = raw: { binds, referrers ? { }, systemLibDirs ? [ ], skip ? [ "debug" "logs" ]
                  , passthruFor ? (_result: _o: { }), checkBound ? (d: d) }:
        if binds == { } then raw else
        let
          outs = raw.outputs or [ "out" ];
          managed = lib.filter (o: !(lib.elem o skip)) outs;
          late = lib.attrNames binds;
          expand = g:
            if isGlob g then lib.filter (o: builtins.match (globRegex g) o != null) managed else [ g ];
          refs = lib.mapAttrs (_: gs: lib.unique (lib.concatMap expand gs)) referrers;
          lstarSet = lib.unique (late ++ lib.concatLists (lib.attrValues refs));
          lstar = lib.filter (o: lib.elem o lstarSet) outs;

          errors =
            lib.concatMap (o: lib.optional (!(lib.elem o outs)) "binds.${o}: not an output of ${raw.name}") late
            ++ lib.concatMap (o: lib.optional (lib.elem o skip) "binds.${o}: ${o} is in skip") late
            ++ lib.concatLists (lib.mapAttrsToList (o: b:
                 map (k: "binds.${o}.${k}: unknown key (interpreters, libs)")
                   (lib.attrNames (removeAttrs b [ "interpreters" "libs" ]))) binds)
            ++ map (k: "referrers.${k}: ${k} is not in binds") (lib.filter (k: !(binds ? ${k})) (lib.attrNames referrers))
            ++ lib.concatLists (lib.mapAttrsToList (k: gs: lib.concatMap (g:
                 if isGlob g then lib.optional (expand g == [ ]) "referrers.${k}: ${g} matches no output"
                 else lib.optional (!(lib.elem g managed)) "referrers.${k}: ${g} is not an output (or is in skip)")
                 gs) referrers)
            ++ lib.optional (lib.elem "out" lstar && (raw.outputName or "out") != "out")
                 "the default output of ${raw.name} is not out";

          # a package: lib.getLib first, then its other outputs (an SRPM's library may
          # sit in any subpackage: zlib-ng's libz.so.1 is in zlib-ng-compat); an
          # output passed directly: only that one
          libEntry = d:
            let
              cands = if d.outputSpecified or false then [ d ]
                else [ (lib.getLib d) ] ++ map (o: d.${o})
                  (lib.filter (o: !(lib.elem o [ "debug" "logs" ])) (d.outputs or [ "out" ]));
              b = baseNameOf "${lib.head cands}";
            in {
              name = builtins.substring 33 (builtins.stringLength b) b;
              dirs = lib.unique (lib.concatMap (p: [ "${p}/lib64" "${p}/lib" ]) cands);
            };
          planBinds = lib.mapAttrs (_: b: {
            hostPath = lib.concatMapStringsSep ":" (d: "${lib.getBin d}/bin") (b.interpreters or [ ]);
            libs = map libEntry (b.libs or [ ]);
          }) binds;
          # stdenv hooks need an `out` (reproducible-builds.sh, multiple-outputs.sh): when
          # L* has none, `out` is an extra output holding only the bind summary
          extraOut = !(lib.elem "out" lstar);

          bound = checkBound (stdenvNoCC.mkDerivation {
            inherit (raw) name;
            outputs = lib.optional extraOut "out" ++ lstar;
            __structuredAttrs = true;
            nativeBuildInputs = [ python3 patchelf ];
            rockyLateBind = {
              storeDir = builtins.storeDir;
              inherit late lstar skip systemLibDirs;
              referrers = refs;
              raw = lib.genAttrs managed (o: "${raw.${o}}");
              binds = planBinds;
              summaryOutput = if extraOut then "out" else null;
            };
            exportReferencesGraph.rawGraph = map (o: raw.${o}) managed;
            outputChecks = lib.genAttrs (lib.optional extraOut "out" ++ lstar)
              (_: { disallowedRequisites = map (o: raw.${o}) lstar; });
            buildCommand = ''
              python3 -I ${tool} bind --plan "$NIX_ATTRS_JSON_FILE" --elf-lib ${partitionTool} \
                --patchelf "$(command -v patchelf)" --shebangs "$TMPDIR/shebangs" --state "$TMPDIR/state.json"
              while IFS=$'\t' read -r o hp dir; do
                HOST_PATH="$hp" patchShebangs --host "$dir"
              done < "$TMPDIR/shebangs"
              python3 -I ${tool} verify --plan "$NIX_ATTRS_JSON_FILE" --state "$TMPDIR/state.json"
            '';
            passthru = { inherit raw late lstar; };
          });

          # one attrset per output, all sharing the overlay (as mkDerivation's outputs do)
          pick = o: base:
            if lib.elem o lstar then base // { inherit (bound.${o}) outPath drvPath; } else base;
          overlay = lib.genAttrs outs (o: outputOf o) // {
            all = map outputOf outs;
            raw = raw;
            bound = bound;
            lateBound = lstar;
            inherit late;
          };
          outputOf = o: pick o raw.${o} // overlay // passthruFor byName o;
          byName = lib.genAttrs outs outputOf;
          top = pick (raw.outputName or "out") raw // overlay // passthruFor byName (raw.outputName or "out");
        in
        if errors != [ ] then
          throw ("lateBind.wrap ${raw.name}:\n  " + lib.concatStringsSep "\n  " errors)
        else top;

      interpreterSrpm = { python3 = "python3.12"; sh = "bash"; };

      resolve = { pkgs, interpreterPkgs ? { } }: ov:
        let
          interp = n: interpreterPkgs.${n} or pkgs.${interpreterSrpm.${n} or n} or null;
          libOf = n: pkgs.${n} or null;
          bindOf = o: b: {
            interpreters = map (n: { inherit n; v = interp n; }) (b.interpreters or [ ]);
            libs = map (n: { inherit n; v = libOf n; }) (b.libs or [ ]);
          };
          r = lib.mapAttrs bindOf (ov.lateBind or { });
          miss = lib.concatLists (lib.mapAttrsToList (o: b:
            map (x: "lateBind.${o}.interpreters: ${x.n}") (lib.filter (x: x.v == null) b.interpreters)
            ++ map (x: "lateBind.${o}.libs: ${x.n}") (lib.filter (x: x.v == null) b.libs)) r);
        in
        {
          inherit miss;
          binds = lib.mapAttrs (_: b: { interpreters = map (x: x.v) b.interpreters; libs = map (x: x.v) b.libs; }) r;
          referrers = ov.lateReferrers or { };
        };
    in
    {
      inherit wrap mk interpreterSrpm tool;
      missing = ctx: ov: (resolve ctx ov).miss;
      fromOverrides = ctx: ov:
        let r = resolve ctx ov; in
        if r.miss != [ ] then throw ("lateBind.fromOverrides: cannot resolve\n  " + lib.concatStringsSep "\n  " r.miss)
        else { inherit (r) binds referrers; };
    };
in
mk { inherit (bootPkgs) stdenvNoCC patchelf python3; inherit partitionTool; }
