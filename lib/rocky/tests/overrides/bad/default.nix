# checks.nn-names fixture: an invalid override file (typo'd keys, a wrong type).
{ ... }: {
  mergeOutput = [ [ "bad" "bad32" ] ];
  doCheck = "yes";
  lateBind.common.interp = [ "bash" ];
}
