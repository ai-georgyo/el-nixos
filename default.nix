# Entry point: returns the Rocky package set. See docs/DESIGN.md.
{ bootPkgs, release ? "10.2" }:
{
  lock = builtins.fromJSON (builtins.readFile (./lock + "/rocky-${release}/srpms.json"));
}
