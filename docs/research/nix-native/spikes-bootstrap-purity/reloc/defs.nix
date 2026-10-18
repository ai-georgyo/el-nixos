let f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos"; s0 = f.legacyPackages.x86_64-linux.stage0;
in s0.lib.runInBuildroot { name = "spike-defs"; buildroot = s0.buildrootFull; script = builtins.readFile ./defs.sh; }
