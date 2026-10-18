#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
static __thread int tls = 42;
static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static long total = 0;
static void *work(void *a){ long n=(long)a; tls += n; for(int i=0;i<100000;i++){pthread_mutex_lock(&m); total++; pthread_mutex_unlock(&m);} return (void*)(long)tls; }
static void *sleeper(void *a){ (void)a; for(;;) pause(); return NULL; }
int main(void){
  pthread_t t[8]; long sum=0;
  for(long i=0;i<8;i++) pthread_create(&t[i],NULL,work,(void*)i);
  for(int i=0;i<8;i++){ void *r; pthread_join(t[i],&r); sum+=(long)r; }
  printf("total=%ld tlssum=%ld main_tls=%d\n", total, sum, tls);
  pthread_t s; pthread_create(&s,NULL,sleeper,NULL); pthread_cancel(s); void *r; pthread_join(s,&r);
  printf("cancelled=%d\n", r==PTHREAD_CANCELED);
  return 0;
}
