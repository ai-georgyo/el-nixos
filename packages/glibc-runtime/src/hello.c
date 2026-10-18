#include <stdio.h>
#include <locale.h>
#include <langinfo.h>
#include <time.h>
#include <wchar.h>
#include <gnu/libc-version.h>
#include <sys/utsname.h>
int main(void){
  const char *l = setlocale(LC_ALL, "");
  printf("glibc %s %s\n", gnu_get_libc_version(), gnu_get_libc_release());
  printf("locale=%s codeset=%s\n", l ? l : "(null)", nl_langinfo(CODESET));
  time_t t = 1700000000; struct tm tm; gmtime_r(&t, &tm);
  char buf[256]; strftime(buf, sizeof buf, "%A %d %B %Y %c", &tm);
  printf("strftime: %s\n", buf);
  printf("printf: %'.2f\n", 1234567.891);
  wchar_t w[] = L"Grüße"; printf("wcslen=%zu mbs=%ls\n", wcslen(w), w);
  return 0;
}
