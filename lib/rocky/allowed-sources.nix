# Plain source files a build-pure (S3/S4) derivation may name (design §7.3).
#
# nixpkgs contributes *source files* only: the generic stdenv (setup.sh,
# builders), the cc/bintools wrapper scripts and the setup hooks they and the
# stdenv install.  Every derivation is supplied by the stage (allowedBuildDrvs);
# any other nixpkgs file -- or the whole nixpkgs tree, which is what
# "${nixpkgsSrc}/..." puts into a string context -- is a purity violation.
#
# A source matches when it is a path value under one of these roots, or a
# store path that is the store copy of a file/directory under them (what
# `"${./x.sh}"` produces; "${repo}" is a copy of the root, named
# <h>-<h0>-source), or lies inside a root given as a store-path string
# (`stage.extraAllowedSources`, a flake's outPath).
{ nixpkgsSrc, repo }:
map (d: nixpkgsSrc + "/${d}") [
  "pkgs/stdenv/generic"                     # setup.sh, builder.sh, default-builder.sh, source-stdenv.sh
  "pkgs/build-support/cc-wrapper"           # cc-wrapper.sh, add-flags.sh, add-hardening.sh, setup-hook.sh
  "pkgs/build-support/bintools-wrapper"     # ld-wrapper.sh, add-flags.sh, add-hardening.sh, setup-hook.sh
  "pkgs/build-support/wrapper-common"       # utils.bash, substituted by both wrappers' postFixup (E6)
  "pkgs/build-support/setup-hooks"          # stdenv default hooks, role.bash, separate-debug-info.sh
  "pkgs/by-name/ex/expand-response-params"  # C source, compiled by the stage (design §5.1)
]
++ [
  repo                                      # this repository (macro files, tools, scripts)
]
