# Entry point: returns the Rocky package set. See docs/DESIGN.md.
{ bootPkgs
, release ? "10.2"
, kernelHeadersRpm ? null # kernel-headers RPM for the glibc buildroot (mkBuildroot rpm spec);
                          # null: Rocky's, rebuilt from the kernel SRPM (stage0.kernelHeadersBuild)
}:
let
  readLock = file: builtins.fromJSON (builtins.readFile (./lock + "/rocky-${release}/${file}"));
  lock = readLock "srpms.json"; # SRPMs: EVR, sha256, BuildRequires (eval-time contract)
  rpmsLock = readLock "rpms.json"; # official binary RPMs (only parsed when used)
  fetch = import ./lib/sources.nix { inherit (bootPkgs) fetchurl; inherit lock rpmsLock; };

  # stage0 buildroot machinery (docs/stage0.md)
  stage0 = import ./bootstrap { pkgs = bootPkgs; inherit lock rpmsLock; inherit (fetch) officialRpms; };

  # milestone 1: the glibc SRPM rebuilt in stage0 (docs/glibc.md)
  glibc = import ./packages/glibc.nix {
    pkgs = bootPkgs;
    inherit stage0 rpmsLock;
    # installed with rpm, so glibc.spec's `rpm -ql kernel-headers` works
    kernelHeadersRpm = if kernelHeadersRpm != null then kernelHeadersRpm
      else { from = stage0.kernelHeadersBuild; names = [ "kernel-headers" ]; };
    inherit (fetch) officialRpms;
  };

  # parity/purity checks against the official RPMs (docs/parity.md)
  parity = import ./lib/parity.nix { pkgs = bootPkgs; inherit rpmsLock stage0; inherit (fetch) fetchRpm; };
in
{
  inherit lock rpmsLock;
  inherit (fetch) fetchSrpm fetchRpm sources officialRpms;
  inherit stage0;
  inherit (parity) mkParityCheck;
  parityChecks = parity.checks // {
    # milestone 1: every glibc subpackage vs the 221 official RPMs
    # (allowlist: tools/parity/glibc.json -> stage0.json -> default.json)
    glibc-parity = parity.mkParityCheck { name = "glibc"; ours = glibc.build; };
    # the headers-only kernel build vs the official kernel-headers and
    # kernel-modules-extra-matched (allowlist: tools/parity/kernel.json)
    kernel-headers-parity = parity.mkParityCheck {
      name = "kernel-headers";
      ours = stage0.kernelHeadersBuild;
      srpm = "kernel";
      exclude = [ ".*" ];
      keep = [ "kernel-headers\\..*" "kernel-modules-extra-matched\\..*" ];
    };
  };
  parityTool = parity.tool; # store path of tools/rpm-parity.py (+ tools/parity/)

  # rpmbuild results by SRPM name ($out/RPMS, $out/SRPMS, $out/logs)
  srpm = { glibc = glibc.build; };
  # binary RPM name -> its payload as an FHS tree (rpmTree, allowedReferences = [ ])
  rpms = glibc.rpms;
  # per-SRPM extras: buildroot, `trees` (all rpms.* in one linkFarm), `sanity`
  packageSets = { inherit glibc; };
}
