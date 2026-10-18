# Relocated glibc parity + runtime checks (design §7.4-§7.6, WP9):
#   nn-parity-selftest       always: synthetic end-to-end test of tools/nn-parity.py
#   nn-glibc-{files,abi,content,closure,runtime}
#                            only once the S1 relocated glibc exists
#                            (rockyBoot.s1.pkgs.glibc, or rockyBoot.s1.glibc);
#                            plain attribute tests, so evaluation never fails
#                            while it does not
{ lib, self, ... }:
let
  s1 = if self ? rockyBoot && self.rockyBoot ? s1 then self.rockyBoot.s1 else { };
  spkgs = if s1 ? pkgs then s1.pkgs else { };
  glibc = if spkgs ? glibc then spkgs.glibc else if s1 ? glibc then s1.glibc else null;
  kh = if spkgs ? kernel-headers then spkgs.kernel-headers else if s1 ? kernel-headers then s1.kernel-headers else null;
  checks = self.nnChecks.glibc ({
    inherit glibc;
    name = "glibc";
  } // lib.optionalAttrs (s1 ? libgccForGlibc) { libgcc = s1.libgccForGlibc; }
    // lib.optionalAttrs (kh != null) { kernelHeaders = "${kh.dev or kh}/include"; });
in
{
  nn-parity-selftest = self.nnChecks.selftest;
} // lib.optionalAttrs (glibc != null) {
  nn-glibc-files = checks.files;
  nn-glibc-abi = checks.abi;
  nn-glibc-content = checks.content;
  nn-glibc-closure = checks.closure;
  nn-glibc-runtime = checks.runtime;
}
