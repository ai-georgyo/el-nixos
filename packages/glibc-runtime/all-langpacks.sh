# every locale of glibc-all-langpacks: locale data and date formatting
set +e +o pipefail
o=/builddir/out
{
  ls -li /usr/lib/locale/ | head
  locale -a | wc -l; locale -a | md5sum
  localedef --list-archive | wc -l
  for l in $(locale -a); do echo "== $l"; LC_ALL=$l locale -k LC_ALL 2>&1; LC_ALL=$l date -d @1700000000 2>&1; done > $o/all-locales.txt
  md5sum $o/all-locales.txt; wc -l $o/all-locales.txt
  for l in ja_JP.UTF-8 zh_CN.UTF-8 ar_SA.UTF-8 hi_IN.UTF-8 ru_RU.UTF-8 tr_TR.UTF-8 th_TH.UTF-8; do LC_ALL=$l date -d @1700000000; LC_ALL=$l ls /nonexistent; done 2>&1
  printf 'b\na\nB\nA\n\xc3\xa4\n\xc3\x84\nz\n' > /tmp/s
  for l in C.UTF-8 de_DE.UTF-8 sv_SE.UTF-8 tr_TR.UTF-8; do echo "$l: $(LC_ALL=$l sort /tmp/s | tr '\n' ' ')"; done
} > $o/report.txt 2>&1
