let s = import ./split.nix {}; sp = import ./reloc-spike.nix {}; lib = (builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos").inputs.nixpkgs.lib;
in lib.genAttrs [ "which" "popt" "xz" "gzip" "libffi" "gmp" "libyaml" "m4" "sed" "diffutils" "libunistring" "redhat-rpm-config" "rocky-release" "attr" "bzip2" "expat" "lz4" "libsepol" "ncurses" "zlib-ng" ]
  (n: s.split { srpm = n; build = sp.reloc.${n}; })
