# nn.toolShim: the rpmbuild tool shim (lib/rocky/tool-shim.sh + mkview.py),
# docs/nix-native-design.md §1.5, §5.4.  An executable store path:
#
#   buildPhase = "${nn.toolShim} -- rpmbuild -bb ...";
#
# with env rockyViewInputs (declared inputs), RPM_CONFIG_DIR (optional) and
# ROCKY_PREFIX_VIEW=1 for the $out self-prefix alias.  A build-time tool
# only: nothing shipped references it.
#
# nn.toolShim.mk { runCommand bash bubblewrap coreutils python3 } instantiates
# it over other tools (later stages: Rocky-built ones); the default uses
# bootPkgs (bootstrap tooling).  nn.toolShim.e2: the E2 experiment
# (lib/rocky/e2, docs/research/nix-native/experiments/E2.md).
args@{ bootPkgs, ... }:
let
  mk = { runCommand, bash, bubblewrap, coreutils, python3 }:
    runCommand "rocky-tool-shim" {
      passthru = { inherit mk; mkview = ../mkview.py; e2 = import ../e2 args; };
    } ''
      {
        echo '#!${bash}/bin/bash'
        sed -e 's|@bash@|${bash}/bin/bash|g' \
            -e 's|@bwrap@|${bubblewrap}/bin/bwrap|g' \
            -e 's|@coreutils@|${coreutils}|g' \
            -e 's|@python3@|${python3}/bin/python3|g' \
            -e 's|@mkview@|${../mkview.py}|g' \
            ${../tool-shim.sh}
      } > $out
      chmod +x $out
      if grep -n '@[a-z0-9]*@' $out; then echo "unsubstituted placeholder" >&2; exit 1; fi
      ${bash}/bin/bash -n $out
    '';
in
mk { inherit (bootPkgs) runCommand bash bubblewrap coreutils python3; }
