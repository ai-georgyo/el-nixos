cd /builddir
FLAGS=$(rpm --eval '%{optflags}')
echo "flags: $FLAGS"
for n in 40 64 96 128 160 200 256 300 400 600; do
  s=$(python3 -c "print('/nix/store/'+'a'*32+'-'+'b'*($n-44-7)+'/lib64/')")
  cat > t.c <<C
#include <string.h>
#include <stdlib.h>
char *f(void) { char *b = malloc(1024); strcpy(b, "$s"); return b; }
char *g(char *b) { memcpy(b, "$s", sizeof "$s"); return b; }
const char *h(void) { return "$s"; }
C
  gcc $FLAGS -fno-lto -c t.c -o t.o 2>&1 | head -3
  cnt=$(python3 -c "
import sys;d=open('t.o','rb').read();s=b'$s';print(d.count(s), d.count(s[:16]), d.count(s[-12:]))")
  echo "len=${#s} contiguous,head16,tail12 counts: $cnt"
done
