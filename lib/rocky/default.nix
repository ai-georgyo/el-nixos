# Nix-native (relocated) packages built from Rocky specs.
# See docs/nix-native-design.md.
#
# Plug-in layout, so independent pieces never edit the same file:
#   lib/rocky/parts/<name>.nix   `args: <value>`            -> self.<name>
#   lib/rocky/checks/<name>.nix  `args: { nn-<x> = drv; }`  -> merged into self.checks
# `args` = { bootPkgs lib nixpkgsSrc lock rpmsLock readLock release fetch stage0 repo self }.
# Parts reach each other through `args.self` (a lazy fixpoint).
{ bootPkgs, lock, rpmsLock, readLock, release, fetch, stage0 }:
let
  inherit (bootPkgs) lib;
  args = {
    inherit bootPkgs lib lock rpmsLock readLock release fetch stage0 self;
    nixpkgsSrc = bootPkgs.path; # nixpkgs sources (setup.sh, cc-wrapper, hooks)
    repo = ../..;
  };
  nixFiles = dir:
    let entries = if builtins.pathExists dir then builtins.readDir dir else { };
    in lib.filter (n: entries.${n} == "regular" && lib.hasSuffix ".nix" n) (lib.attrNames entries);
  importDir = dir: lib.listToAttrs (map (n: {
    name = lib.removeSuffix ".nix" n;
    value = import (dir + "/${n}") args;
  }) (nixFiles dir));
  parts = importDir ./parts;
  self = parts // {
    checks = lib.foldl' (acc: c: acc // c) { } (lib.attrValues (importDir ./checks));
  };
in
self
