#include <stdio.h>
#include <limits.h>

int main() {
  printf("sizes:\n");
  printf("sizeof(short): %lu\n", sizeof(short));
  printf("sizeof(int): %lu\n", sizeof(int));
  printf("sizeof(unsigned int): %lu\n", sizeof(unsigned int));
  printf("sizeof(long): %lu\n", sizeof(long));
  printf("sizeof(unsigned long): %lu\n", sizeof(unsigned long));
  printf("sizeof(long long): %lu\n", sizeof(long long));
  printf("sizeof(unsigned long long): %lu\n\n", sizeof(unsigned long long));

  printf("maxes:\n");
  printf("INT_MAX: %d\n", INT_MAX);
  printf("UINT_MAX: %u\n", UINT_MAX);
  printf("LONG_MAX: %ld\n", LONG_MAX);
  printf("ULONG_MAX: %lu\n", ULONG_MAX);
  printf("LLONG_MAX: %lld\n", LLONG_MAX);
  printf("ULLONG_MAX: %llu\n", ULLONG_MAX);
}
