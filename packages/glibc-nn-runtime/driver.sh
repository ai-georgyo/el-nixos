# glibc behaviour report for checks.nn-glibc-runtime (packages/glibc-nn-runtime).
# POSIX sh, run by the same static busybox in every session:
#   official   chroots of official Rocky RPMs (glibc in /usr, /lib64 links)
#   relocated  bwrap root with no /usr, /lib64, /bin: only the store closure
#              of the relocated glibc outputs and the test programs, /etc
#              copied from the official root, /t, /work
# Everything compared goes through glibc's own programs (PATH) or programs in
# /t compiled against each glibc; busybox only does the plumbing ($BB ...).
# PHASE main     $OUT/report.txt (### items) and $OUT/locales-archive.txt
#                (every locale of the all_langpacks archive: official root
#                with glibc-all-langpacks / relocated LOCALE_ARCHIVE (P2),
#                no LOCPATH); relocated also $OUT/relocated.txt (items with
#                no official counterpart, checked by assertions)
# PHASE locales  $OUT/locales.txt: every locale directory (official root
#                with all langpack RPMs / relocated LOCPATH of the langpack
#                outputs + common)
# Paths are normalised by tools/nn-parity.py runtime.
# Environment: MODE PHASE LDSO LIBC T BB OUT PATH; relocated: LDSO32
# LOCPATH_ALL ARCHIVE GCONV_EXTRA I18NPATH_ALL.
set +e
o=$OUT
export LANG=C.UTF-8
item() { echo "### $1"; }
run() { echo "\$ $*"; "$@" 2>&1; echo "[rc=$?]"; }
sh_() { echo "\$ $1"; $BB sh -c "$1" 2>&1; echo "[rc=$?]"; }
# relocated: the search paths a profile of all glibc outputs exports
if [ "$MODE" = relocated ]; then
  export LOCPATH="$LOCPATH_ALL" GCONV_PATH="$GCONV_EXTRA" I18NPATH="$I18NPATH_ALL"
fi
CATS="LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION"
locale_loop() {   # list file -> one item per locale
  while read -r l; do
    item "loc.$l"
    LC_ALL=$l locale -k $CATS 2>&1
    LC_ALL=$l "$T/loc" 2>&1
    echo "[rc=$?]"
  done < "$1"
}

if [ "$PHASE" = locales ]; then
  if [ "$MODE" = relocated ]; then
    { for d in $(echo "$LOCPATH_ALL" | $BB tr : ' '); do $BB ls "$d"; done; echo C; echo POSIX; } \
      | $BB sort -u > "$o/locale-list.txt"
  else
    locale -a | $BB sort -u > "$o/locale-list.txt"
  fi
  locale_loop "$o/locale-list.txt" > "$o/locales.txt" 2>&1
  echo "driver: done ($MODE $PHASE)"
  exit 0
fi

{
item ldso.version;    run "$LDSO" --version
item ldso.help;       run "$LDSO" --help
item ldso.tunables;   run "$LDSO" --list-tunables
item ldso.diagnostics
# (cpuid leaf 1 EBX holds the APIC id of the CPU the process ran on)
"$LDSO" --list-diagnostics 2>&1 | $BB grep -vE '^(env|auxv)|^x86\.cpu_features\.features\[0x0\]\.cpuid\[0x1\]=' \
  | $BB sed -E 's/^(path\.[a-z_]+)\[0x[0-9a-f]+\]/\1[N]/'
item ldso.verify;     run "$LDSO" --verify "$T/hello"
item ldso.exec;       run "$LDSO" "$T/hello"
item ldso.list;       run "$LDSO" --list "$T/hello"
item ldso.list-thr;   run "$LDSO" --list "$T/thr"
item libc.banner;     run "$LIBC"
item ldconfig.p;      run ldconfig -p
item ldconfig.print-dirs; sh_ 'ldconfig -N -v -X 2>/dev/null | $BB grep -E "^/"'
item locale.default;  run locale
item locale.a;        sh_ 'locale -a | $BB wc -l'
item locale.de;       sh_ 'LANG=de_DE.UTF-8 locale'
item locale.k-ctype;  sh_ 'locale -k LC_CTYPE'
item localedef;       sh_ '$BB mkdir -p /tmp/loc && localedef -i de_DE -f ISO-8859-1 /tmp/loc/de_DE.ISO-8859-1; echo rc=$?; LOCPATH=/tmp/loc LANG=de_DE.ISO-8859-1 locale charmap'
item localedef.list-archive; sh_ 'localedef --list-archive | $BB wc -l'
item iconv.list;      sh_ 'iconv -l | $BB wc -l; iconv -l | $BB md5sum'
for cs in ISO-8859-1 ISO-8859-15 SHIFT_JIS EUC-JP ISO-2022-JP GB18030 GBK BIG5 EUC-KR IBM037 IBM1047 UTF-16LE UTF-32BE UTF-7 KOI8-R CP1252 CP437 EBCDIC-US TCVN5712-1 ARMSCII-8 IBM1364; do
  item "iconv.$cs"
  sh_ "printf 'Gr\\303\\274\\303\\237e \\342\\202\\254 \\346\\227\\245\\346\\234\\254' | iconv -f UTF-8 -t $cs//TRANSLIT | $BB od -An -tx1"
done
item iconv.sjis;      sh_ "printf '\\202\\240\\202\\242' | iconv -f SHIFT_JIS -t UTF-8 | $BB od -An -tx1"
item nss.passwd;      run getent passwd root
item nss.passwd0;     run getent passwd 0
item nss.group;       run getent group root
item nss.hosts;       run getent hosts localhost
item nss.ahosts;      run getent ahosts localhost
item nss.services;    run getent services ssh
item nss.protocols;   run getent protocols tcp
item nss.rpc;         run getent rpc portmapper
item nss.shadow;      run getent shadow root
item nss.nouser;      run getent passwd nonexistentuser
item nss.initgroups;  run getent initgroups root
item getconf.version; run getconf GNU_LIBC_VERSION
item getconf.pthread; run getconf GNU_LIBPTHREAD_VERSION
item getconf.longbit; run getconf LONG_BIT
item getconf.v;       run getconf -v POSIX_V7_LP64_OFF64 LONG_BIT
item getconf.all;     sh_ 'getconf -a | $BB grep -vE "NPROCESSORS|PHYS_PAGES|AVPHYS"'
item tz.zdump;        run zdump -v -c 2024,2025 Europe/Berlin
item tz.tokyo;        sh_ 'TZ=Asia/Tokyo zdump Asia/Tokyo | $BB sed "s/ [0-9:]* [0-9]* JST$/ JST/"'
item gencat;          sh_ 'printf "\$set 1\n1 hallo\n" > /tmp/m.msg && gencat /tmp/m.cat /tmp/m.msg && $BB od -An -tx1 /tmp/m.cat | $BB head -2'
item ldd.hello;       run ldd "$T/hello"
for p in hello dl thr nss m st nss-static m-spie; do
  item "prog.$p"; run "$T/$p"
done
item prog.hello-de;   sh_ "LANG=de_DE.UTF-8 $T/hello"
item prog.hello-en;   sh_ "LANG=en_US.UTF-8 $T/hello"
item prog.dl-debug;   sh_ "LD_DEBUG=libs $T/dl 2>&1 | $BB sed -E 's/^ *[0-9]+://' | $BB grep -vE 'calling (init|fini)'"
item prog.tunables;   sh_ "GLIBC_TUNABLES=glibc.cpu.x86_hwcaps_mask=0 $T/hello | $BB head -1"
item prog.loc-C;      sh_ "LC_ALL=C $T/loc"
} > "$o/report.txt" 2>&1

# every locale of the archive: LOCALE_ARCHIVE (P2), no LOCPATH (relocated);
# the official root with glibc-all-langpacks
if [ "$MODE" = relocated ]; then
  ( unset LOCPATH; export LOCALE_ARCHIVE="$ARCHIVE"
    locale -a | $BB sort -u > "$o/archive-list.txt"
    locale_loop "$o/archive-list.txt" ) > "$o/locales-archive.txt" 2>&1
else
  locale -a | $BB sort -u > "$o/archive-list.txt"
  locale_loop "$o/archive-list.txt" > "$o/locales-archive.txt" 2>&1
fi

if [ "$MODE" = relocated ]; then
{
item r.env.no-usr;     sh_ 'for d in /usr /lib64 /lib /bin /sbin; do [ -e $d ] && echo "$d exists"; done; true'
item r.m32.hello;      run "$T/hello32"
item r.m32.static;     run "$T/m32-static"
item r.m32.ldso;       run "$LDSO32" --help
item r.iconv.no-extra; sh_ 'unset GCONV_PATH; iconv -l | $BB wc -l'
item r.locale.archive; sh_ "unset LOCPATH; export LOCALE_ARCHIVE=$ARCHIVE; LC_ALL=de_DE.UTF-8 locale charmap; LC_ALL=de_DE.UTF-8 $T/loc | $BB head -1"
item r.locale.locpath-wins; sh_ "export LOCALE_ARCHIVE=/nonexistent; LC_ALL=de_DE.UTF-8 $T/loc | $BB head -1"
item r.locale.none;    sh_ "unset LOCPATH LOCALE_ARCHIVE; LC_ALL=de_DE.UTF-8 $T/loc | $BB head -1"
item r.cancel;         run "$T/thr"
item r.cache;          sh_ "LD_DEBUG=libs $T/dl 2>&1 | $BB grep -c 'search cache=/etc/ld.so.cache'"
} > "$o/relocated.txt" 2>&1
fi
echo "driver: done ($MODE $PHASE)"
