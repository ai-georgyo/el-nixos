# tools/nn-parity.py with what it loads (rpm-parity.py, rpm_purity.py,
# abi-compare.py, the allowlists in tools/parity/) as one source store path:
# editing other tools does not rebuild the checks.
{ lib }:
let toolsDir = ../../../tools; in
lib.fileset.toSource {
  root = toolsDir;
  fileset = lib.fileset.unions [
    (toolsDir + "/nn-parity.py") (toolsDir + "/rpm-parity.py") (toolsDir + "/rpm_purity.py")
    (toolsDir + "/abi-compare.py") (toolsDir + "/parity")
  ];
}
