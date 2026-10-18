# nn.nnChecks.glibc: relocated parity + runtime checks of a relocated glibc
# (design §7.4-§7.6, §12 WP9).  A build function, not tied to one derivation:
#
#   nn.nnChecks.glibc {
#     glibc              multi-output relocated glibc: .outputs, .<output>,
#                        passthru.rpmOutputs = { "<rpm name>" = "<output>"; }
#                        (every subpackage, unshipped ones included)
#     cc ? null          C compiler wrapper over it (default nn.cc.wrap { libc = glibc; })
#     libgcc ? nn.libgccForGlibc   the trusted-dir libgcc_s (closure exception, §4.5)
#     kernelHeaders ? <stage0 kernel-headers>/usr/include   include dir for the test programs
#     name ? "glibc"     used in derivation names
#     srpm ? "glibc"     selects rpmsLock.bySrpm.<srpm> (the shipped official RPMs) and the
#                        allowlists tools/parity/nn-<srpm>-<check>.json
#   }
#   -> { files abi content closure runtime }   derivations; each FAILS on an
#      unexpected difference; .report = the same check that always builds;
#      results in $out/report.txt / report.json (runtime: $out/result.txt,
#      $out/compare/report.txt, $out/assertions.txt)
#
#   files    per shipped subpackage: relative file set, types, executable bit,
#            symlink targets vs the official RPM, + the partitioner metadata
#            (modes, flags, owners, caps, Requires/Provides ...) vs its header
#   content  bytes / text after the path map / ELF semantics / archives
#   abi      tools/abi-compare.py over FHS views, through the path map
#   closure  every output's closure inside the siblings + libgcc
#   runtime  packages/glibc-nn-runtime (no /usr, no /lib64) vs the official roots
{ bootPkgs, lib, rpmsLock, fetch, stage0, self, ... }:
let
  pkgs = bootPkgs;
  toolsDir = ../../../tools;
  tool = import ./tool.nix { inherit lib; };
  allowFile = srpm: check:
    let f = "nn-${srpm}-${check}.json"; in
    if builtins.pathExists (toolsDir + "/parity/${f}") then "${tool}/parity/${f}" else null;
in
{ glibc
, cc ? null
, libgcc ? self.libgccForGlibc
, kernelHeaders ? "${stage0.rpms.kernel-headers}/usr/include"
, name ? "glibc"
, srpm ? "glibc"
}:
let
  outputs = glibc.outputs or [ "out" ];
  outPaths = lib.genAttrs outputs (o: glibc.${o}.outPath);
  rpmOutputs = glibc.rpmOutputs or glibc.passthru.rpmOutputs
    or (throw "nn.nnChecks.glibc ${name}: the glibc derivation has no passthru.rpmOutputs");
  shippedKeys = rpmsLock.bySrpm.${srpm};
  official = lib.listToAttrs (map (k: lib.nameValuePair rpmsLock.rpms.${k}.name "${fetch.fetchRpm k}") shippedKeys);
  cc' = if cc != null then cc else self.cc.wrap { libc = glibc; name = "nn-check-${name}"; };

  plan = pkgs.writeText "nn-${name}-plan.json" (builtins.toJSON {
    inherit name rpmOutputs official;
    outputs = outPaths;
    extraAllowed = [ "${libgcc}" ];
  });

  mk = check: { extraInputs ? [ ], args ? "", attrs ? { } }:
    let
      allow = allowFile srpm check;
      drv = failOnDiff: pkgs.runCommand "nn-${name}-${check}" ({
        nativeBuildInputs = [ pkgs.python3 pkgs.zstd ] ++ extraInputs;
        passthru = { inherit plan; } // lib.optionalAttrs failOnDiff { report = drv false; };
        meta.description = "relocated parity (${check}): ${name} vs the official Rocky RPMs";
      } // attrs) ''
        rc=0
        python3 -I ${tool}/nn-parity.py ${check} --plan ${plan} --out $out --workdir $TMPDIR/work \
          ${lib.optionalString (allow != null) "--allow ${allow}"} ${args} || rc=$?
        if [ $rc -ge 2 ]; then echo "nn-parity ${check}: tool error" >&2; exit $rc; fi
        ${lib.optionalString failOnDiff ''
          if [ $rc -ne 0 ]; then
            echo "=== nn-parity ${check} ${name} FAILED; full report: $out/report.txt (build .report to keep it)" >&2
            exit 1
          fi
        ''}
      '';
    in
    drv true;

  # one exportReferencesGraph file per output, named after it
  graphAttrs = {
    exportReferencesGraph = lib.concatMap (o: [ "graph-${o}" glibc.${o} ]) outputs;
  };

  runtimeFor = failOnDiff: import ../../../packages/glibc-nn-runtime {
    inherit pkgs lib stage0 tool;
    officialRpms = fetch.officialRpms;
    allowFile = allowFile srpm "runtime";
  } {
    inherit name glibc outPaths libgcc kernelHeaders failOnDiff;
    cc = cc';
  };
in
{
  inherit plan tool;
  files = mk "files" { };
  content = mk "content" { extraInputs = [ pkgs.binutils-unwrapped ]; };
  abi = mk "abi" { extraInputs = [ pkgs.binutils-unwrapped ]; };
  closure = mk "closure" {
    attrs = graphAttrs;
    args = "--graphs $NIX_BUILD_TOP";
  };
  runtime = runtimeFor true // { report = runtimeFor false; };
}
