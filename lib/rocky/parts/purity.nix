# nn.purity: eval-time build-purity assertion (lib/rocky/purity.nix, design §7.3)
args: import ../purity.nix { inherit (args) lib nixpkgsSrc repo lock fetch; }
