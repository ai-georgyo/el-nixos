/* Locale probe for the relocated-glibc runtime check: everything a locale
   changes, without coreutils (the relocated sandbox has none). */
#define _GNU_SOURCE
#include <errno.h>
#include <langinfo.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wchar.h>
#include <wctype.h>

static const char *words[] = { "b", "a", "B", "A", "\xc3\xa4", "\xc3\x84", "z", "\xc3\xa9", "e", "ch", "c",
                               "\xc4\xb1", "i", "I", "\xc4\xb0" };
#define NWORDS (sizeof words / sizeof words[0])

static int cmp(const void *a, const void *b) { return strcoll(*(const char **)a, *(const char **)b); }

int main(void) {
  const char *l = setlocale(LC_ALL, "");
  printf("setlocale=%s\n", l ? l : "(null)");
  static const nl_item items[] = { CODESET, D_T_FMT, D_FMT, T_FMT, T_FMT_AMPM, RADIXCHAR, THOUSEP, YESEXPR,
                                   NOEXPR, CRNCYSTR, DAY_1, DAY_7, ABDAY_1, MON_1, MON_12, ABMON_1, ERA,
                                   ALT_DIGITS };
  for (size_t i = 0; i < sizeof items / sizeof items[0]; i++) printf("langinfo[%d]=%s\n", (int)i, nl_langinfo(items[i]));
  time_t t = 1700000000; struct tm tm; gmtime_r(&t, &tm);
  char buf[512];
  strftime(buf, sizeof buf, "%c|%x|%X|%A|%B|%p|%Ec|%Ex|%EY|%Od", &tm);
  printf("strftime=%s\n", buf);
  printf("printf=%'.2f|%'d\n", 1234567.891, 9876543);
  printf("strerror=%s\n", strerror(ENOENT));
  const char *w[NWORDS]; memcpy(w, words, sizeof w);
  qsort(w, NWORDS, sizeof w[0], cmp);
  printf("strcoll=");
  for (size_t i = 0; i < NWORDS; i++) printf("%s ", w[i]);
  printf("\n");
  wchar_t ws[] = { L'a', L'ä', L'i', L'ı', L'ß', L'σ', L'一', 0 };
  printf("towupper=");
  for (wchar_t *p = ws; *p; p++) printf("%x/%d ", (unsigned)towupper(*p), wcwidth(*p));
  printf("\n");
  return 0;
}
