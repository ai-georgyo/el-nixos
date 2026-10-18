# nn.rpmConfig: the rpm configuration dir for relocated builds (lib/rocky/rpm/config.nix).
# A derivation (stage0 rpm + stage0's macro packages) that is also callable:
#   nn.rpmConfig { rpm ? stage0.rpm, macroPkgs ? [ ], extraMacroDirs ? [ ], baseMacroPkgs ? ... }
# nn.rpmConfig.configSite = lib/rocky/config.site.
args: import ../rpm/config.nix args
