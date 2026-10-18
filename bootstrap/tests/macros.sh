# In-chroot check of the stage0-full buildroot's rpm configuration.
out=/builddir/out
exec > >(tee "$out/report.txt") 2>&1
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
ev() { rpm --eval "$1"; }

echo "== installed packages"; rpm -qa | sort
for m in '%{dist}' '%{rhel}' '%{el10}' '%{centos}' '%{_vendor}' '%{_target_platform}' '%{_arch}' '%{_target_cpu}' \
         '%{_rpmconfigdir}' '%{_libdir}' '%{_dbpath}' '%{?_annotated_build}' '%{toolchain}' '%{_lto_cflags}' \
         '%{optflags}' '%{build_cflags}' '%{build_cxxflags}' '%{build_ldflags}' '%{?_package_note_flags}' \
         '%{__os_install_post}' '%{?_find_debuginfo_opts}' '%{_include_gdb_index}' '%{_missing_build_ids_terminate_build}'; do
  printf '%s = %s\n' "$m" "$(ev "$m")"
done | tee evals.txt
echo
check "%dist is .el10"                 '[ "$(ev %dist)" = .el10 ]'
check "%rhel is 10"                    '[ "$(ev %rhel)" = 10 ]'
check "%el10 is 1"                     '[ "$(ev %el10)" = 1 ]'
check "_target_platform x86_64-redhat-linux-gnu" '[ "$(ev %_target_platform)" = x86_64-redhat-linux-gnu ]'
check "optflags: -march=x86-64-v3"     'ev %optflags | grep -q -- "-march=x86-64-v3"'
check "optflags: -mtls-dialect=gnu2"   'ev %optflags | grep -q -- "-mtls-dialect=gnu2"'
check "optflags: -fcf-protection"      'ev %optflags | grep -q -- "-fcf-protection"'
check "optflags: _FORTIFY_SOURCE=3"    'ev %optflags | grep -q -- "-D_FORTIFY_SOURCE=3"'
check "optflags: hardened cc1 specs"   'ev %optflags | grep -q -- "-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1"'
check "optflags: no annobin (stage0)"  '! ev %optflags | grep -q annobin'
check "ldflags: -z now / relro"        'ev %build_ldflags | grep -q -- "-Wl,-z,relro" && ev %build_ldflags | grep -q -- "-specs=/usr/lib/rpm/redhat/redhat-hardened-ld"'

echo "== compile with the Rocky flags"
cat > t.c <<'EOF'
#include <stdio.h>
#include <string.h>
__thread int tls;
int main(int argc, char **argv) { char b[16]; strncpy(b, argv[0], sizeof b - 1); b[15] = 0; tls = argc; printf("%s %d\n", b, tls); return 0; }
EOF
CFLAGS=$(ev %build_cflags); LDFLAGS=$(ev %build_ldflags)
echo "gcc $CFLAGS $LDFLAGS t.c"
check "compiles+links with %build_cflags/%build_ldflags" 'gcc $CFLAGS $LDFLAGS -o t t.c'
check "runs" './t'
readelf -nW t | sed -n '1,60p'
check "PIE (hardened)"                 'readelf -hW t | grep -q "DYN (Position-Independent Executable file)"'
check "BIND_NOW"                       'readelf -dW t | grep -q -E "BIND_NOW|FLAGS_1.*NOW"'
check "IBT+SHSTK"                      'readelf -nW t | grep -q "IBT, SHSTK"'
check "x86 ISA needed x86-64-v3"       'readelf -nW t | grep -q "x86 ISA needed: x86-64-baseline, x86-64-v2, x86-64-v3" || readelf -nW t | grep -q "x86-64-v3"'
check "no RPATH/RUNPATH"               '! readelf -dW t | grep -qE "RPATH|RUNPATH"'
echo
if [ $fail = 0 ]; then echo "ALL MACRO CHECKS PASSED"; else echo "SOME MACRO CHECKS FAILED"; exit 1; fi
