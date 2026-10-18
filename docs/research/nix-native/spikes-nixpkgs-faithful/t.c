#include <stdio.h>
#include <locale.h>
#include <iconv.h>
#include <pthread.h>
#include <langinfo.h>
#include <linux/version.h>
static void *th(void *a){ for(;;) pthread_testcancel(); return a; }
int main(int argc, char **argv){
  printf("kernel-headers %d\n", LINUX_VERSION_CODE > 0);
  const char *l = setlocale(LC_ALL, "");
  printf("setlocale(\"\") = %s; CODESET=%s\n", l ? l : "(null)", nl_langinfo(CODESET));
  iconv_t cd = iconv_open("ISO-8859-15", "UTF-8"); printf("iconv ISO-8859-15 (glibc) %s\n", cd==(iconv_t)-1?"FAIL":"ok");
  cd = iconv_open("IBM1364", "UTF-8"); printf("iconv IBM1364 (gconv-extra) %s\n", cd==(iconv_t)-1?"FAIL":"ok");
  if (argc > 1) { pthread_t t; pthread_create(&t,0,th,0); pthread_cancel(t); pthread_join(t,0); printf("pthread_cancel ok\n"); }
  return 0;
}
