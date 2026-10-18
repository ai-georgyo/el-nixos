#include <stdio.h>
#include <crypt.h>
int main(void){ printf("%s\n", crypt("pw","$6$saltsalt$")); return 0; }
