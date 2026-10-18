# stage0 acceptance tests (each is a derivation; output = report.txt).
{ pkgs, lib', buildroot, buildrootFull, which, rpms }:
{
  # C/C++/shared/-m32/-static/LTO in the bare stage0 root
  toolchain = lib'.runInBuildroot {
    name = "stage0-test-toolchain";
    inherit buildroot;
    script = builtins.readFile ./toolchain.sh;
  };
  # same compiler checks again inside stage0-full (macro packages installed)
  toolchainFull = lib'.runInBuildroot {
    name = "stage0-test-toolchain-full";
    buildroot = buildrootFull;
    script = builtins.readFile ./toolchain.sh;
  };
  # rpm --eval of the Rocky flags in stage0-full, compile with them
  macros = lib'.runInBuildroot {
    name = "stage0-test-macros";
    buildroot = buildrootFull;
    script = builtins.readFile ./macros.sh;
  };
  # inspect the RPMs of the `which` build (requires/provides/ELF/store refs)
  whichRpms = lib'.runInBuildroot {
    name = "stage0-test-which-rpms";
    buildroot = buildrootFull;
    binds = { "/inputs/build" = which; };
    script = builtins.readFile ./rpms.sh;
  };
  # rpmTree with allowedReferences = [ ] (fails on any store reference)
  whichTree = rpms.which;
}
