let f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos"; s = f.legacyPackages.x86_64-linux.stage0;
in s.lib.runInBuildroot { name = "spike-store-by-pieces"; buildroot = s.buildrootFull; script = builtins.readFile ./piece-test.sh + "\ncp t.c out/ 2>/dev/null; true"; }
