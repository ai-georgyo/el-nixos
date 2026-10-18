#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
int main(void){
  void *h = dlopen("libm.so.6", RTLD_NOW);
  if(!h){ printf("dlopen failed: %s\n", dlerror()); return 1; }
  double (*c)(double) = (double(*)(double))dlsym(h, "cos");
  double (*e)(double) = (double(*)(double))dlsym(h, "exp");
  if(!c||!e){ printf("dlsym failed: %s\n", dlerror()); return 1; }
  printf("cos(1)=%a exp(1)=%a\n", c(1.0), e(1.0));
  Dl_info di; if(dladdr((void*)c,&di)) printf("cos in %s\n", di.dli_fname);
  void *bad = dlopen("libnonexistent.so", RTLD_NOW); printf("bad=%p err=%s\n", bad, dlerror());
  dlclose(h); return 0;
}
