# In-chroot acceptance test for the stage0 toolchain (runs as mockbuild).
# The compiler must behave like a normal FHS distro compiler: headers from
# /usr/include, crt files + libc from /usr/lib64 (or /usr/lib for -m32),
# PT_INTERP /lib64/ld-linux-x86-64.so.2, no RPATH/RUNPATH, no /nix/store
# strings in what it produces (debug info included).
out=/builddir/out
exec > >(tee "$out/report.txt") 2>&1
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

cd /builddir
echo "== versions"
gcc --version | head -1; g++ --version | head -1; ld --version | head -1; ldd --version | head -1
check "gcc -dumpmachine is x86_64-redhat-linux" '[ "$(gcc -dumpmachine)" = x86_64-redhat-linux ]'
check "gcc -dumpversion is 14" '[ "$(gcc -dumpversion)" = 14 ]'
echo "== search dirs"; gcc -print-search-dirs
echo "== C include search list"
echo | gcc -xc -E -v - 2>&1 | sed -n '/search starts here/,/End of search/p' | tee c-inc.txt
echo "== C++ include search list"
echo | g++ -xc++ -E -v - 2>&1 | sed -n '/search starts here/,/End of search/p' | tee cxx-inc.txt
check "no store dirs in C include path" '! grep -q /nix/store c-inc.txt'
check "no store dirs in C++ include path" '! grep -q /nix/store cxx-inc.txt'
check "/usr/include is the last C include dir" '[ "$(grep -v "^End" c-inc.txt | tail -1 | tr -d " ")" = /usr/include ]'
grep "^ /" cxx-inc.txt | while read -r d; do realpath "$d"; done > cxx-inc-real.txt
check "libstdc++ headers at /usr/include/c++/14" 'grep -qx /usr/include/c++/14 cxx-inc-real.txt'
echo "== -print-file-name"
check "lto-wrapper is FHS" '[[ "$(gcc -print-prog-name=lto-wrapper)" == /usr/libexec/gcc/x86_64-redhat-linux/14/lto-wrapper ]]'
for f in libgcc_s.so libgcc.a libstdc++.so libstdc++.a libc.so libc.so.6 crt1.o crti.o crtbeginS.o include; do
  printf '%-18s %s\n' "$f" "$(gcc -print-file-name=$f)"
  check "-print-file-name=$f is FHS" '[[ "$(gcc -print-file-name=$f)" == /usr/* ]]'
done
check "-m32 libc.so is /usr/lib/libc.so" '[ "$(gcc -m32 -print-file-name=libc.so)" = /usr/lib/../lib/libc.so ] || [ "$(realpath $(gcc -m32 -print-file-name=libc.so))" = /usr/lib/libc.so ]'
check "gcc -print-prog-name=ld is /usr/bin/ld (via PATH)" '[ "$(command -v $(gcc -print-prog-name=ld))" = /usr/bin/ld ]'

cat > hello.c <<'EOF'
#include <stdio.h>
#include <gnu/libc-version.h>
int main(void) { printf("hello from C, glibc %s\n", gnu_get_libc_version()); return 0; }
EOF
cat > hello.cc <<'EOF'
#include <iostream>
#include <string>
#include <vector>
int main() { std::vector<std::string> v{"hello", "from", "C++"}; for (auto &s : v) std::cout << s << ' '; std::cout << __VERSION__ << '\n'; }
EOF
cat > foo.c <<'EOF'
int foo(int x) { return x * 6; }
EOF
cat > usefoo.c <<'EOF'
#include <stdio.h>
int foo(int);
int main(void) { printf("foo(7)=%d\n", foo(7)); return foo(7) == 42 ? 0 : 1; }
EOF

echo "== build"
check "C hello builds"            'gcc -O2 -g -o hello hello.c'
check "C++ hello builds"          'g++ -O2 -g -o hellocc hello.cc'
check "shared lib builds"         'gcc -O2 -g -fPIC -shared -Wl,-soname,libfoo.so.1 -o libfoo.so.1 foo.c && ln -sf libfoo.so.1 libfoo.so'
check "link against shared lib"   'gcc -O2 -g -o usefoo usefoo.c -L. -lfoo'
check "-m32 C hello builds"       'gcc -m32 -O2 -o hello32 hello.c'
check "-static C hello builds"    'gcc -static -O2 -o hello-static hello.c'
check "-flto C hello builds"      'gcc -O2 -flto=auto -ffat-lto-objects -o hello-lto hello.c'
echo "== run"
check "C hello runs"              './hello'
check "C++ hello runs"            './hellocc'
check "shared lib user runs"      'LD_LIBRARY_PATH=. ./usefoo'
check "-m32 hello runs"           './hello32'
check "static hello runs"         './hello-static'
check "lto hello runs"            './hello-lto'
echo "== inspect"
for b in hello hellocc libfoo.so.1 usefoo hello-lto; do
  readelf -lW $b | grep -i 'program interpreter' || true
  readelf -dW $b | grep -E 'NEEDED|RPATH|RUNPATH' || true
  [ $b = libfoo.so.1 ] || check "$b: PT_INTERP /lib64/ld-linux-x86-64.so.2" 'readelf -lW $b | grep -q "interpreter: /lib64/ld-linux-x86-64.so.2]"'
  check "$b: no RPATH/RUNPATH" '! readelf -dW $b | grep -qE "RPATH|RUNPATH"'
  check "$b: no /nix/store strings (incl. debuginfo)" '! strings -a $b | grep -q /nix/store'
done
check "hello32: PT_INTERP /lib/ld-linux.so.2" 'readelf -lW hello32 | grep -q "interpreter: /lib/ld-linux.so.2]"'
check "hellocc resolves libstdc++ from /lib64 via the FHS loader" '/lib64/ld-linux-x86-64.so.2 --list ./hellocc | tee /dev/stderr | grep -q "libstdc++.so.6 => /lib64/libstdc++.so.6"'
check "hello resolves libc from /lib64" '/lib64/ld-linux-x86-64.so.2 --list ./hello | grep -q "libc.so.6 => /lib64/libc.so.6"'
check "debuginfo comp_dir is /builddir" 'readelf --debug-dump=info hello | grep -m1 DW_AT_comp_dir | grep -q /builddir'
check "CET: -fcf-protection binary carries IBT+SHSTK (crt files/libc built with CET)" \
  'gcc -O2 -fcf-protection -o hello-cet hello.c && readelf -nW hello-cet | grep -q "IBT, SHSTK"'
check "build-id note present" 'readelf -nW hello | grep -q "Build ID"'
echo
if [ $fail = 0 ]; then echo "ALL TOOLCHAIN CHECKS PASSED"; else echo "SOME TOOLCHAIN CHECKS FAILED"; exit 1; fi
