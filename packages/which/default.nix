# Per-package overrides for the relocated which (docs/nix-native-design.md
# §8.1; fields: packages/README-overrides.md).
#
# S1: which.spec BuildRequires readline-devel, but Rocky's which links no
# readline (the official which-2.21-44.el10_0 binary NEEDs libc.so.6 only:
# configure uses readline for nothing which installs).  S1 builds no
# readline, so the BuildRequire is dropped here -- for which only: a stage
# fallback entry would drop it silently for every S1 package (M1 review:
# pcre2 then failed in %build without readline/readline.h).
{ lib, stage }:
{
  inputs.drop = lib.optionals (stage.name == "s1") [ "readline-devel" ];
}
