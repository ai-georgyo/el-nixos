# Spike: run the relocated, split outputs directly from /nix/store in the plain
# Nix sandbox (no chroot, no /usr, no /lib64), and list their closures.
{ }:
let
  sp = import ./split.nix { };
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  s = f.legacyPackages.x86_64-linux.stage0;
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  g = sp.glibc;
  finals = [ g g.common g.devel g.langpack-en g.minimal-langpack g.gconv-extra g.utils g.static
             sp.which sp.xz sp.xz.libs sp.popt sp.gzip sp.sed sp.m4 sp.diffutils sp.libffi ];
in
pkgs.runCommand "spike-reloc-runtime" {
  exportReferencesGraph = pkgs.lib.concatMap (o: [ "closure-${baseNameOf o}" o ]) finals;
  nativeBuildInputs = [ ];
} ''
  set +e +o pipefail
  exec > >(tee $TMPDIR/report) 2>&1
  r() { echo "\$ $*"; "$@" 2>&1 | head -${"$"}{N:-8}; echo "  [rc=''${PIPESTATUS[0]}]"; }
  echo "== sandbox has /usr? $(ls -d /usr /lib64 /usr/lib64 2>&1 | tr '\n' ' ')"
  r ${g}/lib64/ld-linux-x86-64.so.2 --version
  N=40 r sh -c "${g}/lib64/ld-linux-x86-64.so.2 --list-diagnostics | grep -E '^path\.|^dl_platform|^env_filtered' "
  r ${g}/lib64/ld-linux-x86-64.so.2 --list ${g.common}/bin/locale
  export LOCPATH=${g.langpack-en}/lib/locale:${g.minimal-langpack}/lib/locale
  N=20 r ${g.common}/bin/locale -a
  r env LC_ALL=en_US.UTF-8 ${g.common}/bin/locale -k LC_NUMERIC
  r sh -c "printf 'caf\xc3\xa9\n' | ${g.common}/bin/iconv -f UTF-8 -t ISO-8859-1 | od -c"
  r sh -c "printf 'abc\n' | ${g.common}/bin/iconv -f UTF-8 -t IBM037 | od -An -tx1"
  r sh -c "printf 'abc\n' | GCONV_PATH=${g}/lib64/gconv:${g.gconv-extra}/lib64/gconv ${g.common}/bin/iconv -f UTF-8 -t IBM037 | od -An -tx1"
  r ${g.common}/bin/getent passwd root
  r ${g.common}/bin/getconf GNU_LIBC_VERSION
  r ${g.common}/bin/ldd ${sp.xz}/bin/xz
  r ${pkgs.bash}/bin/bash ${g.common}/bin/ldd ${sp.xz}/bin/xz
  r ${sp.which}/bin/which --version
  r env PATH=${sp.xz}/bin:${sp.gzip}/bin ${sp.which}/bin/which xz gzip
  r ${sp.xz}/bin/xz --version
  r sh -c "echo hello | ${sp.xz}/bin/xz | ${sp.xz}/bin/xz -d"
  r sh -c "echo hello | ${sp.gzip}/bin/gzip | ${sp.gzip}/bin/gzip -d"
  r sh -c "echo hello world | ${sp.sed}/bin/sed s/world/rocky/"
  r ${sp.m4}/bin/m4 --version
  r ${sp.diffutils}/bin/diff --version
  r ${g}/lib64/ld-linux-x86-64.so.2 --list ${sp.popt}/lib64/libpopt.so.0
  # compile against the relocated glibc-devel with the stage0 gcc (driver from the store)
  cat > hello.c <<'EOF'
  #include <stdio.h>
  #include <locale.h>
  #include <gnu/libc-version.h>
  #include <math.h>
  int main(int c, char **v) { setlocale(LC_ALL, ""); printf("hello from glibc %s, %'.2f, sqrt2=%f\n", gnu_get_libc_version(), 1234567.891, sqrt((double)c + 1)); return 0; }
  EOF
  export PATH=${s.binutils}/usr/bin:${s.gcc}/usr/bin:$PATH
  r gcc -O2 -nostdinc -isystem $(gcc -print-file-name=include) -isystem ${g.devel}/include \
     -B${g.devel}/lib64/ -L${g.devel}/lib64 -static-libgcc -Wl,--dynamic-linker=${g}/lib64/ld-linux-x86-64.so.2 hello.c -o hello -lm
  r ${s.binutils}/usr/bin/readelf -l hello
  r env LC_ALL=en_US.UTF-8 ./hello
  r gcc -O2 -static -nostdinc -isystem $(gcc -print-file-name=include) -isystem ${g.devel}/include \
     -B${g.static}/lib64/ -B${g.devel}/lib64/ -L${g.static}/lib64 -L${g.devel}/lib64 hello.c -o hello-static -lm
  r env LC_ALL=en_US.UTF-8 ./hello-static
  echo "== closures"
  for c in closure-*; do echo "$c: $(grep '^/nix/store' $c | sort -u | sed 's|/nix/store/[a-z0-9]*-||' | tr '\n' ' ')"; done
  mkdir -p $out; cp $TMPDIR/report $out/report.txt
''
