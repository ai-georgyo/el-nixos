#include <stdio.h>
#include <math.h>
int main(void){
  double xs[]={0.1,0.5,1.0,2.5,10.0,100.0,1e-300,1e300};
  for(int i=0;i<8;i++){ double x=xs[i]; printf("%a: sin=%a cos=%a exp=%a log=%a pow=%a tgamma=%a lgamma=%a erf=%a\n",x,sin(x),cos(x),exp(x),log(x),pow(x,1.37),tgamma(x),lgamma(x),erf(x)); }
  float f=0.7f; printf("f: sinf=%a expf=%a powf=%a\n", sinf(f), expf(f), powf(f,2.3f));
  return 0;
}
