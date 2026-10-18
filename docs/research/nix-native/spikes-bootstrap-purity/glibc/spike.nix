let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  lp = f.legacyPackages.x86_64-linux;
  s0 = lp.stage0;
in s0.lib.runInBuildroot {
  name = "spike-reloc-glibc";
  buildroot = lp.packageSets.glibc.buildroot;
  binds = { "/inputs/glibc.src.rpm" = lp.sources.glibc; };
  script = builtins.readFile ./reloc-glibc.sh;
}
