# checks.nn-stage-deps: evaluation-time tests of mkStage's build input
# resolution on the real S1 stages (lib/rocky/stage.nix):
#   * -devel propagation (§5.6, develClosure, lock develrequires.json):
#     glibc-devel brings kernel-headers and libxcrypt-devel along for a
#     package that takes glibc-devel from the stage; nothing propagates for
#     glibc itself (it uses no stage package) or from a fallback entry;
#     a propagated name the stage cannot provide stops evaluation, and
#     inputs.drop names it away
#   * consumer-specific drops are not stage-wide (M1 review): no S1 fallback
#     entry drops a library -devel for one consumer's sake; glibc and which
#     name theirs in their own inputs.drop
{ bootPkgs, lib, self, ... }:
let
  s1 = self.stages.s1;
  g1 = self.stages.s1Glibc1;
  noInputs = { add = [ ]; addBuildOnly = [ ]; addNative = [ ]; drop = [ ]; buildRequires = [ ]; };
  keys = l: map (x: "${x.key}<${toString x.via}") l;
  outPath = p: builtins.unsafeDiscardStringContext (toString p);

  tests = {
    "develClosure: glibc-devel -> kernel-headers, libxcrypt-devel (via glibc-devel)" =
      keys (s1.develClosure "nn-test" { names = [ "glibc-devel" ]; })
      == [ "kernel-headers<glibc-devel" "libxcrypt-devel<glibc-devel" ];
    "develClosure: nothing for glibc itself (usesStagePackage false)" =
      s1.develClosure "glibc" { names = [ "glibc-devel" ]; } == [ ];
    "develClosure: nothing from a name the stage does not build (fallback substitutes)" =
      s1.develClosure "nn-test" { names = [ "readline-devel" "mpfr-devel" ]; } == [ ];
    "develClosure: drop applies" =
      keys (s1.develClosure "nn-test" { names = [ "glibc-devel" ]; drop = [ "libxcrypt-devel" ]; })
      == [ "kernel-headers<glibc-devel" ];
    "resolveBuildDeps: an unprovidable propagated name stops evaluation" =
      !(builtins.tryEval (builtins.seq
        (g1.resolveBuildDeps "nn-test" (noInputs // { buildRequires = [ "glibc-devel" ]; })).host true)).success;
    "resolveBuildDeps: dropped, the rest propagates (kernel-headers is a host input)" =
      let d = g1.resolveBuildDeps "nn-test" (noInputs // { buildRequires = [ "glibc-devel" ]; drop = [ "libxcrypt-devel" ]; }); in
      lib.elem "kernel-headers" (map (x: x.key) d.propagated)
      && lib.elem (outPath g1.rpm.kernel-headers) (map outPath d.host);
    "S1's own packages: nothing propagates" =
      lib.all (s: (s1.resolveBuildDeps s (s1.pkgs.${s}.overrides.inputs)).propagated == [ ]) s1.packages;
    "no S1 fallback entry drops a library -devel for one consumer" =
      lib.all (n: !(s1.fallback.${n} ? drop) || !(lib.hasSuffix "-devel" n) || lib.elem n [ "glibc-devel" "gettext-devel" "python3-devel" ])
        (lib.attrNames s1.fallback);
    "glibc and which name their drops themselves" =
      lib.all (n: lib.elem n s1.pkgs.glibc.overrides.inputs.drop)
        [ "libselinux-devel" "gd-devel" "libpng-devel" "audit-libs-devel" "libcap-devel" "systemtap-sdt-devel" ]
      && lib.elem "readline-devel" s1.pkgs.which.overrides.inputs.drop;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) tests);
in
{
  nn-stage-deps = assert lib.assertMsg (failed == [ ])
    ("nn-stage-deps failed: " + lib.concatStringsSep "; " failed);
    bootPkgs.runCommandLocal "nn-stage-deps" { names = lib.attrNames tests; __structuredAttrs = true; } ''
      mkdir -p $out
      for t in "''${names[@]}"; do echo "ok: $t"; done | tee $out/result.txt
    '';
}
