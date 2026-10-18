# checks.nn-names fixture: a valid override file (names only some arguments).
{ lib, stage }: {
  mergeOutputs = [ [ "good" "good32" ] ];
  doCheck = stage.name == "s3";
  bconds.without = [ "docs" ];
  lateBind.common.interpreters = [ "bash" ];
  lateReferrers.common = [ "langpack_*" ];
  runtimeSearchPaths."lib/locale" = "LOCPATH";
  env = { NIX_NO_SELF_RPATH = "1"; "user-defined-trusted-dirs" = "/x/lib64"; };
  specSubstitutions = [ { from = "a"; to = "b"; } ];
  allowUnresolvedNeeded = lib.optionals (stage.name == "s1") [ "libgd.so.3" ];
}
