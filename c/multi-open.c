#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#define PG_SZ 4096
#define PG_NR 5

int main(int argc, char **argv) {
	int *fds;
	int i;
	int j;
	char buf[PG_NR * PG_SZ];
	int ret;
	char *addr;

	if (argc <= 1) {
		fprintf(stderr, "usage: multi-open <f1> [f2]...");
		return -1;
	}
	fds = malloc(sizeof(int) * (argc - 1));
	if (!fds) {
		fprintf(stderr, "Failed to allocate %d fds\n", argc - 1);
		return ENOMEM;
	}
	for (i = 1; i < argc; ++i) {
		fds[i-1] = open(argv[i], O_RDONLY);
		if (fds[i-1] < 0) {
			fprintf(stderr, "Open failed.\n");
			return errno;
		}
		/*
		ret = read(fds[i-1], buf, PG_NR * PG_SZ);
		if (ret < 0) {
			fprintf(stderr, "Read failed.\n");
			return errno;
		}
		*/
		addr = mmap(NULL, PG_NR * PG_SZ, PROT_READ | PROT_EXEC, MAP_PRIVATE, fds[i-1], 0);
		if (!addr) {
			fprintf(stderr, "Mmap failed.\n");
			return errno;
		}
		for (j = 0; j < PG_NR; ++j) {
			char c = addr[j * PG_SZ];
		}
	}
	sleep(600);
}
