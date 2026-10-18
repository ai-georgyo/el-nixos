# Acceptance test for nn.cc.wrap (checks.nn-cc-toolchain): bootstrap/tests/
# toolchain.sh ported to store paths.  Runs in a plain Nix sandbox (no /usr,
# no /lib64), libc = nn.cc.stage0Libc.  The compiler must behave like a Nix
# compiler that produces Rocky-shaped code: headers and crt files from the
# libc store path, PT_INTERP = the store loader, DT_RUNPATH (never DT_RPATH)
# with store entries, self rpath $out/lib64, and no input store path in the
# DWARF (-ffile-prefix-map hook), no -frandom-seed from the environment.
# Part A: the wrapper as a stdenv input (setup hooks ran: NIX_CFLAGS_COMPILE
# carries nixpkgs' -frandom-seed, NIX_LDFLAGS the self rpath).  Part B: the
# wrapper from PATH with an empty environment and Rocky's %build_cflags /
# %build_ldflags, as mkRpmPackage's tool shim runs it.  Part C: from PATH,
# libc split into out/dev (the relocated glibc's shape); a subset of A/B.
# Environment: WRAPPER LIBC GCC BINUTILS STORESCAN ROCKY_FLAGS PYTHON PATH_B
# BWRAP FARM FARM_T FARM_TF ABS_HDR PATH_C WRAPPER_C LIBC_OUT LIBC_DEV.
mkdir -p "$out"
exec > >(tee "$out/report.txt") 2>&1
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
# Pipelines never end in a reader that exits early (head, grep -q/-m): read
# from here-strings instead (see bootstrap/tests/toolchain.sh).
inStore() { case "$(realpath "$1")" in "$(realpath "$2")"/*) return 0 ;; *) return 1 ;; esac; }
interp() { sed -n 's/.*program interpreter: \(.*\)]/\1/p' <<<"$(readelf -lW "$1")"; }
runpath() { sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p' <<<"$(readelf -dW "$1")"; }
hasRpath() { grep -q '(RPATH)' <<<"$(readelf -dW "$1")"; }
dwarfClean() {  # no store path at all in the DWARF of the given files
  "$PYTHON" -I "$STORESCAN" --debug-only --input "$WRAPPER" --input "$LIBC" --input "$GCC" \
    --input "$BINUTILS" "$@" > scan.txt
  local rc=$?; cat scan.txt; return $rc
}

mkdir -p work && cd work
echo "== environment (setup hooks)"
echo "NIX_CFLAGS_COMPILE=$NIX_CFLAGS_COMPILE"
echo "NIX_LDFLAGS=$NIX_LDFLAGS"
echo "NIX_HARDENING_ENABLE='${NIX_HARDENING_ENABLE-unset}'"
check "nixpkgs' reproducible-builds hook put -frandom-seed into NIX_CFLAGS_COMPILE (the test is meaningful)" \
  '[[ "$NIX_CFLAGS_COMPILE" == *-frandom-seed=* ]]'
check "self rpath is \$out/lib64" '[[ " $NIX_LDFLAGS " == *" -rpath $out/lib64 "* ]]'
check "no hardening flags enabled by default" '[ -z "${NIX_HARDENING_ENABLE-}" ]'

echo "== versions"
for t in gcc g++ cpp ld as ar; do sed -n 1p <<<"$($t --version)"; done
check "gcc is the wrapper" '[ "$(command -v gcc)" = "$WRAPPER/bin/gcc" ]'
check "gcc -dumpmachine is x86_64-redhat-linux" '[ "$(gcc -dumpmachine)" = x86_64-redhat-linux ]'
check "gcc -dumpversion is 14" '[ "$(gcc -dumpversion)" = 14 ]'
check "gcc --version is Red Hat 14.3.1" 'grep -q "14.3.1 .*(Red Hat 14.3.1-4)" <<<"$(gcc --version)"'

echo "== C include search list"
echo | gcc -xc -E -v - 2>&1 | sed -n '/search starts here/,/End of search/p' | tee c-inc.txt
echo "== C++ include search list"
echo | g++ -xc++ -E -v - 2>&1 | sed -n '/search starts here/,/End of search/p' | tee cxx-inc.txt
grep '^ /' c-inc.txt | while read -r d; do realpath "$d"; done > c-inc-real.txt
grep '^ /' cxx-inc.txt | while read -r d; do realpath "$d"; done > cxx-inc-real.txt
check "C include dirs: only the gcc copy and the libc" \
  '! grep -vE "^($(realpath "$GCC")|$(realpath "$LIBC"))/" c-inc-real.txt'
check "C++ include dirs: only the gcc copy and the libc" \
  '! grep -vE "^($(realpath "$GCC")|$(realpath "$LIBC"))/" cxx-inc-real.txt'
check "libc include dir is the last C include dir" '[ "$(tail -n 1 c-inc-real.txt)" = "$(realpath "$LIBC")/include" ]'
check "libstdc++ headers from the gcc copy" 'grep -qx "$(realpath "$GCC")/include/c++/14" cxx-inc-real.txt'
check "kernel headers in the libc include dir" '[ -f "$LIBC/include/linux/version.h" ]'

echo "== -print-file-name / -print-prog-name"
for f in libgcc_s.so libgcc.a libstdc++.so libstdc++.a crtbeginS.o include; do
  p=$(gcc -print-file-name=$f); printf '%-14s %s\n' "$f" "$p"
  check "-print-file-name=$f is in the gcc copy" 'inStore "$p" "$GCC"'
done
for f in libc.so libc.so.6 libc_nonshared.a crt1.o crti.o Scrt1.o; do
  p=$(gcc -print-file-name=$f); printf '%-14s %s\n' "$f" "$p"
  check "-print-file-name=$f is in the libc" 'inStore "$p" "$LIBC"'
done
check "-m32 libc.so is \$LIBC/lib/libc.so" '[ "$(realpath "$(gcc -m32 -print-file-name=libc.so)")" = "$(realpath "$LIBC")/lib/libc.so" ]'
check "-m32 crt1.o is \$LIBC/lib/crt1.o" '[ "$(realpath "$(gcc -m32 -print-file-name=crt1.o)")" = "$(realpath "$LIBC")/lib/crt1.o" ]'
check "gcc -print-prog-name=ld resolves to the bintools wrapper" \
  '[ "$(command -v "$(gcc -print-prog-name=ld)")" = "$(command -v ld)" ] && [[ "$(realpath "$(command -v ld)")" == /nix/store/*-binutils-wrapper-*/bin/ld ]]'

cat > hello.c <<'EOF'
#include <stdio.h>
#include <stddef.h>
#include <linux/version.h>
#include <linux/types.h>
#include <gnu/libc-version.h>
size_t n = LINUX_VERSION_CODE > 0;
__u32 kv = LINUX_VERSION_CODE;
int main(void) { printf("hello from C, glibc %s\n", gnu_get_libc_version()); return n == 1 && kv ? 0 : 1; }
EOF
cat > hello.cc <<'EOF'
#include <iostream>
#include <string>
#include <vector>
#include <stdexcept>
int main() {
  std::vector<std::string> v{"hello", "from", "C++"};
  for (auto &s : v) std::cout << s << ' ';
  try { throw std::runtime_error("unwound"); } catch (const std::exception &e) { std::cout << e.what() << ' '; }
  std::cout << __VERSION__ << '\n';
}
EOF
printf 'int foo(int x) { return x * 6; }\n' > foo.c
cat > usefoo.c <<'EOF'
#include <stdio.h>
int foo(int);
int main(void) { printf("foo(7)=%d\n", foo(7)); return foo(7) == 42 ? 0 : 1; }
EOF
# a header in a store path (this derivation's own $out is writable while it
# builds) that expands __FILE__: -I<store>/include is mapped to /usr/include
mkdir -p "$out/include"
printf 'static const char *where = __FILE__;\n' > "$out/include/rocky-where.h"
cat > file.c <<'EOF'
#include <stdio.h>
#include <rocky-where.h>
int main(void) { puts(where); return 0; }
EOF

echo "== A: build (stdenv environment)"
check "C hello builds"            'gcc -O2 -g -o hello hello.c'
check "C++ hello builds"          'g++ -O2 -g -o hellocc hello.cc'
check "shared lib builds"         'gcc -O2 -g -fPIC -shared -Wl,-soname,libfoo.so.1 -o libfoo.so.1 foo.c && ln -sf libfoo.so.1 libfoo.so'
check "link against shared lib"   'gcc -O2 -g -o usefoo usefoo.c -L. -lfoo'
check "-m32 C hello builds"       'gcc -m32 -O2 -g -o hello32 hello.c'
check "-static C hello builds"    'gcc -static -O2 -g -o hello-static hello.c'
check "-flto C hello builds"      'gcc -O2 -g -flto=auto -ffat-lto-objects -o hello-lto hello.c'
check "slim LTO: plain nm/ar read -fno-fat-lto-objects objects (LTO plugin in the binutils copy)" \
  'gcc -O2 -flto -fno-fat-lto-objects -c -o foo-thin.o foo.c && grep -q " T foo" <<<"$(nm foo-thin.o)" && ar rcs libthin.a foo-thin.o && grep -q " T foo" <<<"$(nm libthin.a)"'
check "slim LTO: a program links against the slim archive" 'gcc -O2 -flto -o usethin usefoo.c libthin.a'
check "C hello object builds"     'gcc -O2 -g -c -o hello.o hello.c'
check "__FILE__ in a header under -I<store>/include reads /usr/include/..." \
  'gcc -O2 -I"$out/include" -o file file.c && [ "$(./file)" = /usr/include/rocky-where.h ]'
rm -r "$out/include"
echo "== A: run"
check "C hello runs"              './hello'
check "C++ hello runs (exception unwinds: libgcc_s found)" './hellocc'
check "shared lib user runs"      'LD_LIBRARY_PATH=. ./usefoo'
check "-m32 hello runs"           './hello32'
check "static hello runs"         './hello-static'
check "lto hello runs"            './hello-lto'
check "slim-LTO archive user runs" './usethin'
echo "== A: inspect"
for b in hello hellocc usefoo hello-lto libfoo.so.1; do
  echo "-- $b: interp=$(interp $b) runpath=$(runpath $b)"
  readelf -dW $b | grep -E 'NEEDED|RPATH|RUNPATH' || true
  [ $b = libfoo.so.1 ] || check "$b: PT_INTERP is the store loader" '[ "$(interp $b)" = "$LIBC/lib64/ld-linux-x86-64.so.2" ]'
  check "$b: no DT_RPATH" '! hasRpath $b'
done
for b in hello hellocc usefoo hello-lto; do
  check "$b: DT_RUNPATH entries are store paths" \
    'rp=$(runpath $b); [ -n "$rp" ] && ! tr ":" "\n" <<<"$rp" | grep -v "^/nix/store/"'
  check "$b: DT_RUNPATH has the self rpath \$out/lib64, not \$out/lib" \
    'rp=":$(runpath $b):"; [[ $rp == *":$out/lib64:"* && $rp != *":$out/lib:"* ]]'
done
check "hello: DT_RUNPATH has \$LIBC/lib64" '[[ ":$(runpath hello):" == *":$LIBC/lib64:"* ]]'
check "hellocc: DT_RUNPATH has the gcc copy's lib64" '[[ ":$(runpath hellocc):" == *":$GCC/lib64:"* ]]'
check "hello32: PT_INTERP is the 32-bit store loader" '[ "$(interp hello32)" = "$LIBC/lib/ld-linux.so.2" ]'
check "hello32: no DT_RPATH" '! hasRpath hello32'
check "hello-static: no PT_INTERP, no dynamic section" '[ -z "$(interp hello-static)" ] && grep -q "no dynamic section" <<<"$(readelf -dW hello-static)"'
check "hello resolves libc from \$LIBC (loader --list)" \
  'x=$("$LIBC/lib64/ld-linux-x86-64.so.2" --list ./hello); echo "$x"; grep -q "libc.so.6 => $LIBC/lib64/libc.so.6" <<<"$x"'
check "hellocc resolves libstdc++ and libgcc_s from the gcc copy" \
  'x=$("$LIBC/lib64/ld-linux-x86-64.so.2" --list ./hellocc); echo "$x"; grep -q "libstdc++.so.6 => $GCC/lib64/libstdc++.so.6" <<<"$x" && grep -q "libgcc_s.so.1 => $GCC/lib64/libgcc_s.so.1" <<<"$x"'
echo "== A: DWARF"
check "no store path in the DWARF of any binary or object (full or pieced)" \
  'dwarfClean hello hellocc usefoo libfoo.so.1 hello32 hello-static hello-lto hello.o'
for b in hello hello.o hello32 hello-lto; do
  readelf --debug-dump=info $b > info-$b.txt 2>/dev/null
  readelf --debug-dump=line $b > line-$b.txt 2>/dev/null
  check "$b: DW_AT_producer without -frandom-seed" '! grep -q -- -frandom-seed info-$b.txt'
  check "$b: line table names /usr/include (libc headers mapped)" 'grep -q "/usr/include$" line-$b.txt'
  check "$b: line table names /usr/lib/gcc/x86_64-redhat-linux/14/include (gcc prefix mapped)" \
    'grep -q "/usr/lib/gcc/x86_64-redhat-linux/14/include$" line-$b.txt'
done
check "hello: line table names /usr/include/asm-generic (kernel headers mapped)" 'grep -q "/usr/include/asm-generic$" line-hello.txt'
grep -m1 DW_AT_producer info-hello.txt
check "debuginfo comp_dir is the build directory" \
  'grep -m1 DW_AT_comp_dir info-hello.txt | grep -qF "$PWD"'
check "CET: -fcf-protection binary carries IBT+SHSTK (crt files/libc built with CET)" \
  'gcc -O2 -fcf-protection -o hello-cet hello.c && grep -q "IBT, SHSTK" <<<"$(readelf -nW hello-cet)"'
check "build-id note present" 'grep -q "Build ID" <<<"$(readelf -nW hello)"'
check "a -frandom-seed the build passes itself is kept" \
  'gcc -g -c -frandom-seed=keepme -o seed.o foo.c && grep -q -- -frandom-seed=keepme <<<"$(readelf --debug-dump=info seed.o)"'
nmaps() { grep -c -- -ffile-prefix-map <<<"$(NIX_DEBUG=1 "$@" 2>&1)"; }
check "no maps for probes (gcc -v, --version, -dumpversion, -print-file-name=include; NIX_DEBUG)" \
  '[ "$(nmaps gcc -v)" = 0 ] && [ "$(nmaps gcc --version)" = 0 ] && [ "$(nmaps gcc -dumpversion)" = 0 ] && [ "$(nmaps gcc -print-file-name=include)" = 0 ]'
check "maps for a compile (control for the probe check)" '[ "$(nmaps gcc -c -o probe.o foo.c)" -gt 0 ]'

echo "== A: prefix map coverage (declared inputs, symlink farms, -include, store sources)"
echo "NIX_ROCKY_MAP_ROOTS=${NIX_ROCKY_MAP_ROOTS-}"
check "the setup hook put the inputs into NIX_ROCKY_MAP_ROOTS" '[[ " ${NIX_ROCKY_MAP_ROOTS-} " == *" $WRAPPER "* ]]'
check "fixtures are not inputs (only the hook's own scan can map them)" \
  '! grep -qE "$FARM|$FARM_T|$FARM_TF|$ABS_HDR" <<<"${NIX_ROCKY_MAP_ROOTS-}"'
cat > farm.c <<'EOF'
#include <rocky-farm.h>
#include <rocky-fhs.h>
int main(void) { return rocky_farm(1) + rocky_fhs(1) - 5; }
EOF
lnk=$FARM/include/rocky-farm.h; tgt=$(realpath "$lnk")
lnk2=$FARM/include/rocky-fhs.h; tgt2=$(realpath "$lnk2")
echo "farm: $lnk (${#lnk}) -> $tgt (${#tgt}); $lnk2 (${#lnk2}) -> $(readlink "$lnk2") (${#tgt2})"
check "farm precondition: the symlinks' realpaths are shorter (gcc then names the header by them)" \
  '[ -L "$lnk" ] && [[ $tgt == "$FARM_T"/* ]] && (( ${#tgt} < ${#lnk} )) && [ -L "$lnk2" ] && [[ $tgt2 == "$FARM_TF"/usr/include/* ]] && (( ${#tgt2} < ${#lnk2} ))'
check "control: unwrapped gcc, -isystem farm, only the farm mapped: DWARF names the target store paths" \
  '"$GCC/bin/gcc" -O0 -g -isystem "$FARM/include" -ffile-prefix-map="$FARM=/usr" -c -o farm-control.o farm.c && x=$(readelf --debug-dump=line farm-control.o) && grep -qF "$FARM_T/include" <<<"$x" && grep -qF "$FARM_TF/usr/include" <<<"$x"'
check "-isystem farm: the targets' roots are mapped (NIX_DEBUG)" \
  'x=$(NIX_DEBUG=1 gcc -O0 -g -isystem "$FARM/include" -c -o farm.o farm.c 2>&1) && grep -qxF -- "  -ffile-prefix-map=$FARM_T=/usr" <<<"$x" && grep -qxF -- "  -ffile-prefix-map=$FARM_TF/usr=/usr" <<<"$x"'
check "-isystem farm: walk cached in \$TMPDIR/.rocky-cc-linkroots" '[ -f "$TMPDIR/.rocky-cc-linkroots/${FARM#/nix/store/}" ]'
check "-isystem farm: no store path in the DWARF" 'dwarfClean farm.o'
readelf --debug-dump=line farm.o > line-farm.txt
check "-isystem farm: line table names /usr/include (no /usr/usr)" 'grep -q "/usr/include$" line-farm.txt && ! grep -q /usr/usr line-farm.txt'
check "-idirafter farm and joined -isystem<farm> (cached walk): no store path in the DWARF" \
  'gcc -O0 -g -idirafter "$FARM/include" -c -o farm2.o farm.c && gcc -O0 -g -isystem"$FARM/include" -c -o farm3.o farm.c && dwarfClean farm2.o farm3.o'
printf 'int main(void) { return rocky_farm(-1); }\n' > use-inc.c
check "-include <store>/x.h: no store path in the DWARF" \
  'gcc -O0 -g -include "$FARM_T/include/rocky-farm.h" -c -o inc.o use-inc.c && dwarfClean inc.o'
check "a source file in the store: no store path in the DWARF, __FILE__ mapped" \
  'gcc -O0 -g -o src "$FARM_T/rocky-src.c" && dwarfClean src && [ "$(./src)" = /usr/rocky-src.c ]'
printf '#include "%s/include/rocky-abs.h"\nint main(void) { return rocky_abs(0); }\n' "$ABS_HDR" > abs.c
check "control: an absolute #include of a store header not in NIX_ROCKY_MAP_ROOTS stays in the DWARF" \
  'gcc -O0 -g -c -o abs-control.o abs.c && grep -qF "$ABS_HDR" <<<"$(readelf --debug-dump=line abs-control.o)"'
check "absolute #include of a root in NIX_ROCKY_MAP_ROOTS: no store path in the DWARF" \
  'NIX_ROCKY_MAP_ROOTS="${NIX_ROCKY_MAP_ROOTS-} $ABS_HDR" gcc -O0 -g -c -o abs.o abs.c && dwarfClean abs.o'

echo "== A: NIX_ENFORCE_PURITY=1 (stdenv) and /usr as the view of declared inputs"
check "stdenv set NIX_ENFORCE_PURITY=1 and Nix NIX_STORE (the test is meaningful)" \
  '[ "${NIX_ENFORCE_PURITY-}" = 1 ] && [ -n "${NIX_STORE-}" ]'
check "cc and ld wrappers keep -I/-isystem/-L/-rpath under /usr (no 'skipping impure path')" \
  'x=$(NIX_DEBUG=1 gcc -I/usr/include/glib-2.0 -isystem /usr/include/foo -o pur usefoo.c foo.c -L/usr/lib64 -Wl,-rpath,/usr/lib64 2>&1) && ! grep -q "impure path" <<<"$x" && grep -qxF -- "  -I/usr/include/glib-2.0" <<<"$x" && [[ ":$(runpath pur):" == *":/usr/lib64:"* ]]'
mkdir -p view/include/rockyview view/lib64
printf 'int rockyview(void);\n' > view/include/rockyview/rockyview.h
printf 'int rockyview(void) { return 42; }\n' > rv.c
printf '#include <rockyview.h>\nint main(void) { return rockyview() == 42 ? 0 : 1; }\n' > useview.c
gcc -O2 -fPIC -shared -Wl,-soname,librockyview.so.1 -o view/lib64/librockyview.so.1 rv.c && ln -sf librockyview.so.1 view/lib64/librockyview.so
inView() { "$BWRAP" --bind /nix /nix --bind "$NIX_BUILD_TOP" "$NIX_BUILD_TOP" --proc /proc --dev /dev --tmpfs /tmp \
  --ro-bind "$PWD/view" /usr --chdir "$PWD" -- "$@"; }
check "in a /usr view (bwrap, stdenv environment): -I/usr/include/x -L/usr/lib64 -rpath /usr/lib64 build, run" \
  'inView gcc -O2 -I/usr/include/rockyview -o useview useview.c -L/usr/lib64 -lrockyview -Wl,-rpath,/usr/lib64 && inView ./useview && [[ ":$(runpath useview):" == *":/usr/lib64:"* ]]'

echo
echo "== B: from PATH, empty environment, Rocky %build_cflags/%build_ldflags"
CFLAGS_R=$(< "$ROCKY_FLAGS/cflags"); CXXFLAGS_R=$(< "$ROCKY_FLAGS/cxxflags"); LDFLAGS_R=$(< "$ROCKY_FLAGS/ldflags")
echo "CFLAGS=$CFLAGS_R"; echo "LDFLAGS=$LDFLAGS_R"
mkdir -p ../b && cp hello.c hello.cc foo.c usefoo.c ../b/ && cd ../b
rb() { env -i PATH="$PATH_B" HOME=/homeless-shelter TMPDIR="$TMPDIR" "$@"; }
check "env -i: gcc is the wrapper" '[ "$(rb sh -c "command -v gcc")" = "$WRAPPER/bin/gcc" ]'
# shellcheck disable=SC2086
check "C hello (Rocky flags) builds" 'rb gcc $CFLAGS_R $LDFLAGS_R -o hello hello.c'
check "C++ hello (Rocky flags) builds" 'rb g++ $CXXFLAGS_R $LDFLAGS_R -o hellocc hello.cc'
check "shared lib (Rocky flags) builds" 'rb gcc $CFLAGS_R -fPIC $LDFLAGS_R -shared -Wl,-soname,libfoo.so.1 -o libfoo.so.1 foo.c && ln -sf libfoo.so.1 libfoo.so'
check "cc / c++ / x86_64-redhat-linux-gcc / cpp work" \
  'rb cc $CFLAGS_R $LDFLAGS_R -o usefoo usefoo.c -L. -lfoo && rb c++ -O2 -o hellocc2 hello.cc && rb x86_64-redhat-linux-gcc -O2 -o hello2 hello.c && rb cpp hello.c > hello.i && rb x86_64-redhat-linux-gcc-14 -O2 -c foo.c -o foo2.o'
check "as / ld / ar / gcc-ar / nm from PATH" \
  'rb gcc $CFLAGS_R -c foo.c -o foo.o && rb gcc-ar rcs libfoo.a foo.o && rb ar t libfoo.a | grep -qx foo.o && rb nm libfoo.a | grep -q " T foo" && rb as --version >/dev/null && rb ld --version >/dev/null'
check "slim LTO from PATH: plain ar/nm handle -fno-fat-lto-objects, the archive links" \
  'rb gcc -O2 -flto -fno-fat-lto-objects -c foo.c -o foo-thin.o && rb ar rcs libthin.a foo-thin.o && grep -q " T foo" <<<"$(rb nm libthin.a)" && rb gcc -O2 -flto -o usethin usefoo.c libthin.a && ./usethin'
check "C hello (Rocky flags) runs" './hello'
# With --as-needed the program does not NEED libm.so.6 itself; libstdc++ does,
# and a DT_RUNPATH only serves the object's own NEEDED entries.  A relocated
# glibc's loader has <glibc>/lib64 as system dir (design §4.2) and finds it;
# stage0Libc's loader still has the FHS system dirs (/lib64, /usr/lib64),
# so here the libc dir plays the system dir through LD_LIBRARY_PATH.
check "C++ hello (Rocky flags) runs (libc dir as the loader's system dir)" 'LD_LIBRARY_PATH=$LIBC/lib64 ./hellocc'
check "usefoo (Rocky flags) runs" 'LD_LIBRARY_PATH=. ./usefoo'
for b in hello hellocc usefoo; do
  echo "-- $b: interp=$(interp $b) runpath=$(runpath $b)"
  check "B $b: PT_INTERP is the store loader" '[ "$(interp $b)" = "$LIBC/lib64/ld-linux-x86-64.so.2" ]'
  check "B $b: DT_RUNPATH (store entries), no DT_RPATH" \
    'rp=$(runpath $b); [ -n "$rp" ] && ! tr ":" "\n" <<<"$rp" | grep -v "^/nix/store/" && ! hasRpath $b'
  check "B $b: PIE, BIND_NOW, GNU_RELRO (redhat-hardened specs applied)" \
    'grep -q "DYN (Position-Independent Executable" <<<"$(readelf -hW $b)" && grep -qE "FLAGS.*BIND_NOW|FLAGS_1.*NOW" <<<"$(readelf -dW $b)" && grep -q GNU_RELRO <<<"$(readelf -lW $b)"'
done
readelf --debug-dump=info hello > info-hello.txt 2>/dev/null
grep -m1 DW_AT_producer info-hello.txt
check "B: producer records Rocky's switches (-march=x86-64-v3 -mtls-dialect=gnu2 -fcf-protection)" \
  'grep -m1 DW_AT_producer info-hello.txt | grep -q -- "-march=x86-64-v3.*-mtls-dialect=gnu2.*-fcf-protection"'
check "B: producer without -ffile-prefix-map or store paths" \
  '! grep DW_AT_producer info-hello.txt | grep -qE -- "-ffile-prefix-map|/nix/store"'
check "B: no store path in the DWARF (full or pieced)" 'dwarfClean hello hellocc usefoo libfoo.so.1 foo.o'

echo
echo "== C: libc split into out/dev (the relocated glibc's shape), from PATH, empty environment"
mkdir -p ../c && cp hello.c hello.cc ../c/ && cd ../c
rc() { env -i PATH="$PATH_C" HOME=/homeless-shelter TMPDIR="$TMPDIR" "$@"; }
check "C: gcc is the split-libc wrapper" '[ "$(rc sh -c "command -v gcc")" = "$WRAPPER_C/bin/gcc" ]'
fromDev() { local f; for f in "$@"; do inStore "$(rc gcc -print-file-name=$f)" "$LIBC_DEV" || return 1; done; }
check "C: crt1.o, libc.so, libc_nonshared.a, libc.a from dev" 'fromDev crt1.o libc.so libc_nonshared.a libc.a'
check "C: -m32 crt1.o and libc.so from out/lib (glibc32 merged into out)" \
  '[ "$(realpath "$(rc gcc -m32 -print-file-name=crt1.o)")" = "$(realpath "$LIBC_OUT")/lib/crt1.o" ] && [ "$(realpath "$(rc gcc -m32 -print-file-name=libc.so)")" = "$(realpath "$LIBC_OUT")/lib/libc.so" ]'
check "C: C hello (Rocky flags) builds" 'rc gcc $CFLAGS_R $LDFLAGS_R -o hello hello.c'
check "C: C++ hello (Rocky flags) builds" 'rc g++ $CXXFLAGS_R $LDFLAGS_R -o hellocc hello.cc'
check "C: -m32 hello builds" 'rc gcc -m32 -O2 -g -o hello32 hello.c'
check "C: -static hello builds" 'rc gcc -static -O2 -g -o hello-static hello.c'
check "C: hello: PT_INTERP is out's loader" '[ "$(interp hello)" = "$LIBC_OUT/lib64/ld-linux-x86-64.so.2" ]'
check "C: hello32: PT_INTERP is out's 32-bit loader" '[ "$(interp hello32)" = "$LIBC_OUT/lib/ld-linux.so.2" ]'
check "C: no DT_RPATH" '! hasRpath hello && ! hasRpath hellocc && ! hasRpath hello32'
for b in hello hellocc hello32; do
  echo "-- C $b: interp=$(interp $b) runpath=$(runpath $b)"
  check "C $b: DT_RUNPATH entries are store paths" 'rp=$(runpath $b); [ -n "$rp" ] && ! tr ":" "\n" <<<"$rp" | grep -v "^/nix/store/"'
done
for b in hello hellocc; do
  check "C $b: PIE, BIND_NOW, GNU_RELRO (redhat-hardened specs applied)" \
    'grep -q "DYN (Position-Independent Executable" <<<"$(readelf -hW $b)" && grep -qE "FLAGS.*BIND_NOW|FLAGS_1.*NOW" <<<"$(readelf -dW $b)" && grep -q GNU_RELRO <<<"$(readelf -lW $b)"'
done
readelf --debug-dump=info hello > info-hello.txt 2>/dev/null
check "C: producer records Rocky's switches, no -frandom-seed, no maps, no store path" \
  'p=$(grep -m1 DW_AT_producer info-hello.txt) && grep -q -- "-march=x86-64-v3.*-fcf-protection" <<<"$p" && ! grep -qE -- "-frandom-seed|-ffile-prefix-map|/nix/store" <<<"$p"'
# out/lib64 is the relocated glibc loader's system dir (design §4.2); stage0's
# loader gets it through LD_LIBRARY_PATH
check "C: hello runs" 'LD_LIBRARY_PATH=$LIBC_OUT/lib64 ./hello'
check "C: C++ hello runs" 'LD_LIBRARY_PATH=$LIBC_OUT/lib64 ./hellocc'
check "C: -m32 hello runs (libc.so.6 through DT_RUNPATH out/lib)" './hello32'
check "C: static hello runs" './hello-static'
check "C: no store path in the DWARF (full or pieced)" \
  '"$PYTHON" -I "$STORESCAN" --debug-only --input "$WRAPPER_C" --input "$LIBC_OUT" --input "$LIBC_DEV" --input "$GCC" hello hellocc hello32 hello-static'

echo
if [ $fail = 0 ]; then echo "ALL CC-WRAPPER CHECKS PASSED"; else echo "SOME CC-WRAPPER CHECKS FAILED"; exit 1; fi
