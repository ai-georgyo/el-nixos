#include <stdio.h>
#include <pwd.h>
#include <grp.h>
#include <netdb.h>
#include <string.h>
#include <arpa/inet.h>
int main(void){
  struct passwd *p = getpwuid(0); printf("pw: %s %s %s\n", p?p->pw_name:"-", p?p->pw_dir:"-", p?p->pw_shell:"-");
  struct group *g = getgrnam("root"); printf("gr: %s %d\n", g?g->gr_name:"-", g?(int)g->gr_gid:-1);
  struct addrinfo hints={0},*res; hints.ai_family=AF_UNSPEC; hints.ai_socktype=SOCK_STREAM;
  int rc=getaddrinfo("localhost","ssh",&hints,&res); printf("gai rc=%d\n",rc);
  if(!rc) for(struct addrinfo*a=res;a;a=a->ai_next){ char b[64]; void*x=a->ai_family==AF_INET?(void*)&((struct sockaddr_in*)a->ai_addr)->sin_addr:(void*)&((struct sockaddr_in6*)a->ai_addr)->sin6_addr; printf("  %d %s\n",a->ai_family,inet_ntop(a->ai_family,x,b,sizeof b)); }
  struct servent *s=getservbyname("http","tcp"); printf("serv http=%d\n", s?ntohs(s->s_port):-1);
  return 0;
}
