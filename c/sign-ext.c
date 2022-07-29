#include <stdio.h>

#define SZ_2G (1 << 31)
#define NEG_1 (-1)

int main() {
	unsigned long long ull_2g = SZ_2G;
	unsigned long long ull_neg_1 = NEG_1;
	unsigned u_2g = SZ_2G;
	unsigned long long ull_2g_two_cast = u_2g;
	unsigned long long ull_neg1_nomacro = -1;
	printf("0x%016llx\n", ull_2g);
	printf("0x%016llx\n", ull_neg_1);
	printf("0x%016llx\n", ull_neg1_nomacro);
	printf("0x%016llx\n", ull_2g_two_cast);
}
