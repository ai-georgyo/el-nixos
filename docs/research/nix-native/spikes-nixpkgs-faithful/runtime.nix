# Spike D: the relocated glibc (spike B) as the libc of a nixpkgs cc-wrapper; compile & run
# programs directly from the store (no chroot, no FHS), check closures and union dirs.
let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  ccw = import ./ccwrap.nix;
  glibc0 = import ./glibc-reloc.nix;
  glibc = glibc0 // { libdir = "/lib64/"; incdir = "/include"; };
  # Rocky kernel headers live in their own store path (propagated by glibc-devel in the design)
  kh = f.legacyPackages.x86_64-linux.stage0.rpms.kernel-headers;
  khH = pkgs.runCommand "rocky-kernel-headers" { } "mkdir $out; ln -s ${kh}/usr/include $out/include";
  bintools = (pkgs.wrapBintoolsWith { bintools = ccw.bintools.bintools; libc = glibc; }).overrideAttrs (o: {
    postFixup = o.postFixup + "echo ${glibc}/lib64/ld-linux-x86-64.so.2 > $out/nix-support/dynamic-linker\n";
  });
  cc = (pkgs.wrapCCWith { cc = ccw.cc.cc; inherit bintools; libc = glibc; }).overrideAttrs (o: {
    postFixup = o.postFixup + ": > $out/nix-support/cc-cflags-before\n";
  });
  progs = pkgs.writeText "t.c" ''
    #include <stdio.h>
    #include <stdlib.h>
    #include <locale.h>
    #include <iconv.h>
    #include <pthread.h>
    #include <time.h>
    #include <langinfo.h>
    #include <linux/version.h>
    static void *th(void *a){ for(;;) pthread_testcancel(); return a; }
    int main(int argc, char **argv){
      printf("kernel-headers %d\n", LINUX_VERSION_CODE > 0);
      const char *l = setlocale(LC_ALL, "");
      printf("setlocale(\"\") = %s; CODESET=%s\n", l ? l : "(null)", nl_langinfo(CODESET));
      iconv_t cd = iconv_open("EBCDIC-US", "UTF-8"); printf("iconv EBCDIC-US (gconv-extra? no: in glibc) %s\n", cd==(iconv_t)-1?"FAIL":"ok");
      cd = iconv_open("IBM1364", "UTF-8"); printf("iconv IBM1364 (gconv-extra) %s\n", cd==(iconv_t)-1?"FAIL":"ok");
      if (argc > 1) { pthread_t t; pthread_create(&t,0,th,0); pthread_cancel(t); pthread_join(t,0); printf("pthread_cancel ok\n"); }
      return 0;
    }
  '';
in pkgs.runCommand "spike-relocated-glibc-runtime" { nativeBuildInputs = [ cc ]; buildInputs = [ khH ]; } ''
  set +e
  export NIX_HARDENING_ENABLE=
  G=${glibc}
  exec > >(tee $TMPDIR/report.txt) 2>&1
  echo "== ld.so"; $G/lib64/ld-linux-x86-64.so.2 --version | head -1
  $G/lib64/ld-linux-x86-64.so.2 --list-diagnostics | grep -E '^path\.|^version' 
  $G/lib64/ld-linux-x86-64.so.2 --help | sed -n '/Shared library search path/,/^$/p'
  echo "== compile + run against relocated glibc (cc-wrapper)"
  gcc -O2 ${progs} -o t -lpthread
  readelf -lW t | grep interpreter; readelf -dW t | grep -E 'NEEDED|RPATH|RUNPATH'
  ./t || echo "exit $?"
  echo "== LANG=C.UTF-8 (C.utf8 dir is glibc-common's)"; LANG=C.UTF-8 ./t
  echo "== LANG=de_DE.UTF-8 (locale-archive is glibc-all-langpacks')"; LANG=de_DE.UTF-8 ./t; LANG=de_DE.UTF-8 $G/bin/locale -k LC_TIME | grep -m1 day=
  echo "== pthread_cancel (libc dlopens libgcc_s.so.1)"; ./t cancel || echo "exit $?"
  echo "== with LD_LIBRARY_PATH=<gcc libs>"; LD_LIBRARY_PATH=${ccw.cc.cc}/lib64 ./t cancel || echo "exit $?"
  echo "== store binaries from the relocated glibc"
  bash $G/bin/ldd ./t; head -1 $G/bin/ldd $G/bin/mtrace $G/bin/tzselect $G/bin/sotruss
  $G/bin/getconf GNU_LIBC_VERSION; $G/bin/iconv -l | wc -l; echo hé | $G/bin/iconv -f UTF-8 -t ISO-8859-1 | od -c | head -1
  $G/bin/getent passwd root; $G/bin/locale -a | wc -l
  echo "== TZ (glibc built with sysconfdir=\$out/etc reads $G/etc/localtime)"; strings $G/lib64/libc.so.6 | grep -E 'localtime$|zoneinfo|ld.so.cache|gconv$|/locale$' | sed "s|$G|\$G|"
  mkdir -p $out; cp t $out/; cp $TMPDIR/report.txt $out/
''
