# glibc behaviour report, run as root inside a root made only of RPMs
# (packages/glibc-runtime/default.nix).  Everything printed here must be the
# same with our glibc RPMs and with the official ones; /t holds programs
# compiled against each glibc-devel (/t/ours, /t/off).
set +e +o pipefail
o=/builddir/out
run() { echo "\$ $*"; "$@" 2>&1; echo "[rc=$?]"; }
sh_() { echo "\$ $1"; bash -c "$1" 2>&1; echo "[rc=$?]"; }
sec() { echo; echo "######## $*"; }
LDSO=/usr/lib64/ld-linux-x86-64.so.2
{
sec env
sh_ 'ls -d /nix /nix/store 2>&1; cat /proc/self/mountinfo | grep -c nix'
sh_ 'grep -m1 "model name" /proc/cpuinfo | sed "s/.*: //"'
sec rpm
cat /rpm-qa.txt
echo "--- rpm -Va"
cat /rpm-Va.txt
sec ld.so
run $LDSO --version
run $LDSO --help
run $LDSO --list-tunables
sh_ "$LDSO --list-diagnostics | grep -vE '^(env|auxv|path\.system_dirs|x86\.cpu_features\.(data|cache|rep|level)|x86\.processor|x86\.cpuid)' "
run $LDSO --verify /usr/bin/bash
run $LDSO /usr/bin/true
run /usr/lib64/libc.so.6
sec ldd
run ldd /usr/bin/bash
run ldd /usr/bin/coreutils
run ldd /usr/lib64/libc.so.6
run ldd /usr/bin/iconv
sec ldconfig
run ldconfig -p
run ldconfig -N -v
sh_ 'ls -la /etc/ld.so.cache /etc/ld.so.conf /etc/ld.so.conf.d'
sec locale
run locale -a
run locale
sh_ 'LANG=de_DE.UTF-8 locale'
sh_ 'LANG=de_DE.UTF-8 date -d @1700000000'
sh_ 'LANG=de_DE.UTF-8 TZ=Europe/Berlin date -d @1700000000 "+%c %Z %x %X %A %B"'
sh_ 'LANG=en_US.UTF-8 TZ=America/New_York date -d @1700000000'
sh_ 'LANG=fr_FR.UTF-8 date -d @1700000000'
sh_ 'LANG=de_DE.UTF-8 locale -k LC_NUMERIC LC_MONETARY LC_TIME LC_ADDRESS'
sh_ 'LANG=de_DE.UTF-8 ls /nonexistent'
sh_ 'LANG=C.UTF-8 locale -k LC_CTYPE'
sec localedef
sh_ 'mkdir -p /tmp/loc && localedef -i de_DE -f ISO-8859-1 /tmp/loc/de_DE.ISO-8859-1 && LOCPATH=/tmp/loc LANG=de_DE.ISO-8859-1 locale charmap && LOCPATH=/tmp/loc LC_ALL=de_DE.ISO-8859-1 date -d @1700000000 | od -c | head -3'
sh_ 'localedef --list-archive | head'
sec iconv
sh_ 'iconv -l | wc -l; iconv -l | md5sum'
for cs in ISO-8859-1 ISO-8859-15 SHIFT_JIS EUC-JP ISO-2022-JP GB18030 GBK BIG5 EUC-KR IBM037 IBM1047 UTF-16LE UTF-32BE UTF-7 KOI8-R CP1252 CP437 EBCDIC-US TCVN5712-1 ARMSCII-8; do
  sh_ "printf 'Gr\\xc3\\xbc\\xc3\\x9fe \\xe2\\x82\\xac \\xe6\\x97\\xa5\\xe6\\x9c\\xac' | iconv -f UTF-8 -t $cs//TRANSLIT | od -An -tx1 | tr -s ' '"
done
sh_ "printf '\\x82\\xa0\\x82\\xa2' | iconv -f SHIFT_JIS -t UTF-8 | od -An -tx1"
sh_ 'ls /usr/lib64/gconv | wc -l; ls -la /usr/lib64/gconv/gconv-modules.cache; iconvconfig -o /tmp/gc.cache && cmp /tmp/gc.cache /usr/lib64/gconv/gconv-modules.cache && echo cache-identical-to-regenerated'
sec nss
run getent passwd root
run getent passwd 0
run getent group root
run getent hosts localhost
run getent ahosts localhost
run getent services ssh
run getent protocols tcp
run getent rpc portmapper
run getent shadow root
run getent passwd nonexistentuser
run getent -s db passwd root
run getent initgroups root
run cat /etc/nsswitch.conf
sec getconf
run getconf GNU_LIBC_VERSION
run getconf GNU_LIBPTHREAD_VERSION
run getconf LONG_BIT
run getconf PAGESIZE
run getconf -v POSIX_V7_LP64_OFF64 LONG_BIT
sh_ 'getconf -a | grep -vE "NPROCESSORS|PHYS_PAGES|AVPHYS" | md5sum; getconf -a | wc -l'
sh_ 'getconf -a | grep -vE "NPROCESSORS|PHYS_PAGES|AVPHYS"'
sec tz
run zdump -v -c 2024,2025 Europe/Berlin
sh_ 'TZ=Asia/Tokyo date -d @0'
sec misc-utils
run gencat --version
run sotruss --help
sh_ 'printf "\$set 1\n1 hallo\n" > /tmp/m.msg && gencat /tmp/m.cat /tmp/m.msg && od -An -tx1 /tmp/m.cat | head -2'
run pldd 1
run sprof --version
run makedb --version
sh_ 'printf ".root root:x:0:0:root:/root:/bin/bash\n=0 root:x:0:0:root:/root:/bin/bash\n0 root:x:0:0:root:/root:/bin/bash\n" > /tmp/p.txt; makedb -o /var/db/passwd.db /tmp/p.txt && getent -s db passwd root'
sec compiled
for b in ours off; do
  for p in hello dl thr nss m crypt st nss-static m-spie; do
    [ -e /t/$b/$p ] || { echo "(no /t/$b/$p)"; continue; }
    run /t/$b/$p
  done
  sh_ "LANG=de_DE.UTF-8 /t/$b/hello"
  sh_ "LANG=en_US.UTF-8 /t/$b/hello"
  run ldd /t/$b/hello
  run ldd /t/$b/thr
  run ldd /t/$b/st
  run $LDSO --verify /t/$b/hello
  sh_ "LD_DEBUG=libs /t/$b/dl 2>&1 | sed -E 's/^ *[0-9]+://' | head -40"
  sh_ "GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX2_Usable,-AVX_Fast_Unaligned_Load /t/$b/m | head -2"
  sh_ "GLIBC_TUNABLES=glibc.cpu.x86_hwcaps_mask=0 /t/$b/hello | head -1"
  sh_ "LD_SHOW_AUXV=1 /t/$b/hello | grep -E 'AT_HWCAP|AT_PLATFORM|AT_BASE_PLATFORM'"
done
} > $o/report.txt 2>&1
cp /rpm-Va.txt /rpm-qa.txt $o/
echo done
