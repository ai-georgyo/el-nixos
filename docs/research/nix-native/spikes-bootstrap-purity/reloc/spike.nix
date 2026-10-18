let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  lp = f.legacyPackages.x86_64-linux;
  s0 = lp.stage0;
in s0.lib.runInBuildroot {
  name = "spike-reloc-which";
  buildroot = s0.buildrootFull;
  binds = { "/inputs/which.src.rpm" = lp.sources.which; };
  script = builtins.readFile ./reloc-which.sh;
}
