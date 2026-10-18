# rocky-partition (design §2, tools/rocky-partition/PLAN.md): the in-build
# step that splits rpmbuild's BUILDROOT into one Nix output per subpackage.
#
#   self.partitionTool          a plain source store path (no derivation, so it
#                               is an allowed build input in every stage):
#                               $tool/rocky-partition (entry script) + $tool/rocky_partition/
#   usage in a builder:         python3 -I ${partitionTool}/rocky-partition --plan "$NIX_ATTRS_JSON_FILE"
#   self.partitionTool.trees    relocated rpmbuild trees used by the tests
#                               (tools/rocky-partition/tests/trees.nix: glibc, e3.*)
{ bootPkgs, lib, stage0, ... }:
let
  root = ../../../tools/rocky-partition;
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [ (root + "/rocky-partition") (root + "/rocky_partition") ];
  };
in
{
  outPath = "${src}";
  entry = "${src}/rocky-partition";
  trees = import (root + "/tests/trees.nix") { pkgs = bootPkgs; inherit stage0; };
}
