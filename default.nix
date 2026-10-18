# Entry point: returns the Rocky package set. See docs/DESIGN.md.
{ bootPkgs, release ? "10.2" }:
let
  lock = builtins.fromJSON (builtins.readFile (./lock + "/rocky-${release}/srpms.json"));
in
{
  inherit lock;

  # stage0 buildroot machinery (docs/stage0.md)
  stage0 = import ./bootstrap { pkgs = bootPkgs; inherit lock; };
}
