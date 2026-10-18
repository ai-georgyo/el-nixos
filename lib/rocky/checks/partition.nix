# rocky-partition checks (design §2, tools/rocky-partition/PLAN.md):
#   nn-partition-selftest  synthetic trees: every phase and error class, real
#                          rpmbuild headers, compiled ELF fixtures, --replay
#   nn-partition-replay    the [NF-S3] relocated glibc build tree (kept with
#                          tools/rocky-partition/tests/trees.nix) replayed into
#                          the real 224 outputs (223 subpackage outputs, glibc32
#                          merged into out, + debug): 0 errors, nothing of the
#                          old prefix left (contents and path names), no
#                          dangling symlink, and Nix itself
#                          accepts the outputs (no reference cycle)
{ bootPkgs, lib, stage0, rpmsLock, self, ... }:
let
  pkgs = bootPkgs;
  tool = self.partitionTool;
  selftest = ../../../tools/rocky-partition/tests/selftest.py;

  # output names of design §2.12 (prefix -> out, -devel -> dev, -libs -> lib,
  # <srpm>-X -> X, others verbatim, [^A-Za-z0-9_] -> _), after merges
  outputName = srpm: merges: sub:
    let
      rep = (lib.findFirst (g: lib.elem sub g) [ sub ] merges);
      n = lib.head rep;
      special = { ${srpm} = "out"; "${srpm}-devel" = "dev"; "${srpm}-libs" = "lib"; };
    in special.${n} or (lib.replaceStrings [ "-" "." "+" ] [ "_" "_" "_" ] (lib.removePrefix "${srpm}-" n));

  # glibc: the shipped subpackages (rpms.json) + the unshipped ones of rpmspec -q
  glibcSubs = lib.unique (map (k: rpmsLock.rpms.${k}.name) rpmsLock.bySrpm.glibc)
    ++ [ "glibc32" "sysroot-x86_64-el10-glibc" "compat-libpthread-nonshared" ];
  glibcOverrides = import ../../../tools/rocky-partition/tests/glibc-overrides.nix;
  glibcMap = lib.genAttrs glibcSubs (outputName "glibc" glibcOverrides.mergeOutputs);
  glibcTree = tool.trees.glibc;
in
{
  nn-partition-selftest = pkgs.runCommandCC "nn-partition-selftest"
    {
      nativeBuildInputs = [ pkgs.python3 pkgs.rpm pkgs.patchelf ];
      # fixtures carry exactly the RUNPATH the test gives them
      NIX_DONT_SET_RPATH = "1"; NIX_NO_SELF_RPATH = "1"; NIX_HARDENING_ENABLE = "";
    } ''
    python3 -I ${selftest} ${tool} $TMPDIR/st | tee $TMPDIR/selftest.txt
    mkdir -p $out; cp $TMPDIR/selftest.txt $out/
  '';

  nn-partition-replay = pkgs.stdenvNoCC.mkDerivation {
    name = "glibc-2.39-142.el10_2";       # same length as the tree's prefix (same-length remap)
    outputs = lib.unique ([ "out" ] ++ lib.attrValues glibcMap ++ [ "debug" ]);
    __structuredAttrs = true;
    nativeBuildInputs = [ pkgs.python3 pkgs.zstd ];
    rockyPlan = glibcOverrides // {
      srpm = "glibc";
      rpm = "${stage0.rpm}/usr/bin/rpm";
      rpmConfigDir = "${stage0.rpm}/usr/lib/rpm";
      patchelf = "${pkgs.patchelf}/bin/patchelf";
      subpackages = glibcMap;
    };
    passthru = { inherit glibcMap; tree = glibcTree; };
    buildCommand = ''
      python3 -I ${tool}/rocky-partition --plan "$NIX_ATTRS_JSON_FILE" --replay ${glibcTree}/buildtree
      python3 -I - "$out/nix-support/rocky-report.json" "$NIX_ATTRS_JSON_FILE" ${glibcTree}/buildtree/prefix <<'EOF'
      import json, os, sys
      r = json.load(open(sys.argv[1]))
      outs = json.load(open(sys.argv[2]))["outputs"]
      old = os.path.basename(open(sys.argv[3]).read().strip())
      s = r["summary"]
      # the remap covers path names too (the debug tree mirrors the prefix), so
      # no name keeps the old prefix and no symlink (debug build-id links) dangles
      names, dangling = [], []
      for p in outs.values():
          for d, dirs, files in os.walk(p):
              for x in dirs + files:
                  q = os.path.join(d, x)
                  if old in x:
                      names.append(q)
                  if os.path.islink(q) and not os.path.exists(q):
                      dangling.append(q)
      print("replay: %d outputs, %d subpackages, %d errors, %d warnings, cycles %s, replay leftovers %d,"
            " old-prefix names %d, dangling links %d"
            % (len(r["outputs"]), len(r["subpackages"]), s["errors"], s["warnings"], r["graph"]["sccs"],
               len(r["replay"]["leftovers"]), len(names), len(dangling)))
      for q in (names + dangling)[:20]:
          print("  " + q)
      assert len(r["outputs"]) == 224 and s["errors"] == 0 and not r["graph"]["sccs"], s
      assert not names and not dangling and not r["replay"]["leftovers"]
      EOF
    '';
  };
}
