# Spike S6: use the per-subpackage outputs (S5) like nixpkgs packages: glibc.dev as the
# cc-wrapper's libc headers/crt/libc.so, glibc (out) at run time, union dirs via env.
{ merges ? [ ] }:
let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  ccw = import ./ccwrap.nix;
  g = import ./split.nix { inherit merges; };
  # Rocky puts crt*.o, libc.so (ld script) and libc_nonshared.a in glibc-devel: the wrappers'
  # "lib" (where -B/-L point) is therefore the dev output; the dynamic linker is in out.
  libc = g // { lib = g.dev; libdir = "/lib64/"; incdir = "/include"; };
  kh = f.legacyPackages.x86_64-linux.stage0.rpms.kernel-headers;
  khH = pkgs.runCommand "rocky-kernel-headers" { } "mkdir $out; ln -s ${kh}/usr/include $out/include";
  bintools = (pkgs.wrapBintoolsWith { bintools = ccw.bintools.bintools; inherit libc; }).overrideAttrs (o: {
    postFixup = o.postFixup + "echo ${g.out}/lib64/ld-linux-x86-64.so.2 > $out/nix-support/dynamic-linker\n";
  });
  cc = (pkgs.wrapCCWith { cc = ccw.cc.cc; inherit bintools libc; }).overrideAttrs (o: {
    postFixup = o.postFixup + ": > $out/nix-support/cc-cflags-before\n";
  });
  progs = ./t.c;
in pkgs.runCommand "spike-split-glibc-runtime" { nativeBuildInputs = [ cc ]; buildInputs = [ khH ]; } ''
  set +e
  export NIX_HARDENING_ENABLE=
  exec > >(tee $TMPDIR/report.txt) 2>&1
  G=${g.out}
  echo "== outputs: out=$G dev=${g.dev} common=${g.common}"
  cat ${g.dev}/lib64/libc.so | grep GROUP
  $G/lib64/ld-linux-x86-64.so.2 --list-diagnostics | grep -E '^path\.'
  gcc -O2 ${progs} -o t -lpthread
  readelf -lW t | grep interpreter; readelf -dW t | grep -E 'NEEDED|RPATH|RUNPATH'
  echo "== default env"; ./t
  echo "== LANG=C.UTF-8 (C.utf8 is in glibc-common)"; LANG=C.UTF-8 ./t
  echo "== LANG=C.UTF-8 LOCPATH=common"; LANG=C.UTF-8 LOCPATH=${g.common}/lib/locale ./t
  echo "== de_DE via langpack LOCPATH"; LANG=de_DE.UTF-8 LOCPATH=${g.langpack_de}/lib/locale ./t
  echo "== de_DE via all_langpacks archive (needs LOCALE_ARCHIVE patch P2)"; LANG=de_DE.UTF-8 ./t
  echo "== GCONV_PATH=gconv_extra"; GCONV_PATH=${g.gconv_extra}/lib64/gconv ./t
  echo "== pthread_cancel"; ./t cancel || echo "exit $?"
  echo "== common's programs"; bash ${g.common}/bin/ldd ./t; ${g.common}/bin/getconf GNU_LIBC_VERSION; ${g.common}/bin/iconv -l | wc -l
  LOCPATH=${g.langpack_de}/lib/locale LANG=de_DE.UTF-8 ${g.common}/bin/locale -k LC_TIME | grep -m1 '^day='
  mkdir -p $out; cp t $out/; cp $TMPDIR/report.txt $out/
''
