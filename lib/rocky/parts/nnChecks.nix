# nn.nnChecks: relocated parity + runtime checks (design §7.4-§7.6, WP9).
#
#   nn.nnChecks.glibc { glibc; cc ? null; libgcc ?; kernelHeaders ?; name ?; srpm ? }
#                       -> { files abi content closure runtime plan tool }
#                       (lib/rocky/nn-checks/glibc.nix; tools/nn-parity.py,
#                       packages/glibc-nn-runtime)
#   nn.nnChecks.selftest  synthetic end-to-end test of every comparator
#                       (checks.nn-parity-selftest; lib/rocky/nn-checks/selftest.nix)
#   nn.nnChecks.tool    the tool source (tools/nn-parity.py + what it loads)
#   nn.nnChecks.dev.replay  the same checks over the nn-partition-replay outputs
#                       (the [NF-S3] spike glibc tree partitioned into 224
#                       outputs: P1 as a sed, no P2/P3, no trusted dirs,
#                       leaked build inputs) -- development input until
#                       rockyBoot.s1.glibc exists
args@{ lib, ... }:
let
  glibc = import ../nn-checks/glibc.nix args;
  replay = (import ../checks/partition.nix args).nn-partition-replay;
in
{
  inherit glibc;
  tool = import ../nn-checks/tool.nix { inherit lib; };
  selftest = import ../nn-checks/selftest.nix args;
  dev = {
    replay = glibc {
      glibc = replay // { rpmOutputs = replay.glibcMap; };
      name = "glibc-replay";
    };
  };
}
