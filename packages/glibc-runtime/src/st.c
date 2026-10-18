#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <iconv.h>
#include <math.h>
static void *w(void *a){ return (void*)((long)a*2); }
int main(void){
  pthread_t t; void *r; pthread_create(&t,NULL,w,(void*)21); pthread_join(t,&r);
  printf("static thread=%ld sqrt2=%a\n",(long)r, sqrt(2.0));
  iconv_t cd = iconv_open("ISO-8859-15","UTF-8");
  if(cd==(iconv_t)-1){ perror("iconv_open"); return 1; }
  char in[]="\xe2\x82\xac", out[8]={0}; char *ip=in,*op=out; size_t il=3, ol=8;
  size_t n=iconv(cd,&ip,&il,&op,&ol); printf("iconv rc=%zd byte=%02x\n", n, (unsigned char)out[0]);
  char *p=malloc(1<<20); memset(p,1,1<<20); free(p);
  return 0;
}
