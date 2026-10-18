# In-chroot check of buildrootFullKernelHeaders: Rocky's kernel-headers RPM is
# installed and registered in the rpmdb (glibc.spec's sysroot step runs
# `rpm -ql kernel-headers`), and every kernel UAPI header under /usr/include
# belongs to it (no leftovers from the nixpkgs headers of the plain stage0 root).
out=/builddir/out
exec > >(tee "$out/report.txt") 2>&1
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

echo "kernel-headers: $(rpm -q kernel-headers)"
check "kernel-headers registered in the rpmdb" 'rpm -q kernel-headers >/dev/null'
# Owner/group/mode/mtime cannot verify in a store-path layer: files are owned
# by the (unmapped) store owner, the store makes them 0444/0555 and sets
# mtime 1.  Digest, size, link target and file type must verify.
rpm -V kernel-headers | head -5 || true
check "rpm -V (content: digest/size/links) kernel-headers is clean" \
  '[ -z "$(rpm -V --nouser --nogroup --nomode --nomtime kernel-headers)" ]'
check "provides kernel-headers(x86-64)" 'rpm -q --provides kernel-headers | grep -q "^kernel-headers(x86-64) = "'
n=$(rpm -ql kernel-headers | grep -c '^/usr/include/')
echo "rpm -ql kernel-headers | grep ^/usr/include: $n paths"
check "rpm -ql lists the headers (glibc sysroot step)" '[ "$n" -gt 1000 ]'

# every file in the kernel's UAPI dirs is owned by kernel-headers
rpm -ql kernel-headers | LC_ALL=C sort > owned
find /usr/include/linux /usr/include/asm /usr/include/asm-generic /usr/include/drm \
     /usr/include/rdma /usr/include/sound /usr/include/scsi /usr/include/misc /usr/include/mtd \
     /usr/include/xen /usr/include/video /usr/include/fwctl /usr/include/regulator /usr/include/cxl \
     /usr/include/config 2>/dev/null | LC_ALL=C sort > present || true
# glibc (not kernel-headers) ships these three in Rocky; here they come from
# the stage0 glibc, which is not in the rpmdb
printf '%s\n' /usr/include/scsi/scsi.h /usr/include/scsi/scsi_ioctl.h /usr/include/scsi/sg.h >> owned
LC_ALL=C sort -o owned owned
LC_ALL=C comm -23 present owned > unowned
echo "unowned paths in kernel header dirs: $(wc -l < unowned)"; head -20 unowned
check "no unowned files in the kernel header dirs" '[ ! -s unowned ]'
check "linux/version.h is Rocky's (RHEL_MAJOR 10)" 'grep -q "#define RHEL_MAJOR 10" /usr/include/linux/version.h'
check "LINUX_VERSION_CODE = 6.12" 'grep -q "LINUX_VERSION_CODE 396288" /usr/include/linux/version.h'

# the compiler still works with these headers
cat > t.c <<'EOF'
#include <linux/version.h>
#include <sys/syscall.h>
#include <asm/unistd.h>
#include <stdio.h>
int main(void) { printf("%d %d\n", LINUX_VERSION_CODE, SYS_openat2); return 0; }
EOF
check "gcc -m64 against the headers" 'gcc -O2 t.c -o t64 && ./t64'
check "gcc -m32 against the headers" 'gcc -m32 -O2 t.c -o t32 && ./t32'

echo
if [ $fail = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
