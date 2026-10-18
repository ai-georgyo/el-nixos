# 32-bit (glibc32, ours only: Rocky does not publish it)
set +e +o pipefail
o=/builddir/out
run() { echo "\$ $*"; "$@" 2>&1; echo "[rc=$?]"; }
sh_() { echo "\$ $1"; bash -c "$1" 2>&1; echo "[rc=$?]"; }
{
  run /t/ours/hello32
  run /t/ours/m32-static
  run ldd /t/ours/hello32
  sh_ "LANG=de_DE.UTF-8 /t/ours/hello32"
  run /usr/lib/ld-linux.so.2 --help
  run /usr/lib/libc.so.6
  cat /t/ours/hello32.log
} > $o/report.txt
