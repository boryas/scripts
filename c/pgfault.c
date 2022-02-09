#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

enum modes {
	RD = 1,
	WR = 2
};

int do_one(size_t sz, int mode) {
	char x;
	char *buf = malloc(sz);
	int i;

	if (!buf) {
		return -ENOMEM;
	}
	for (i = 0; i < sz; i += 4096) {
		if (mode & RD)
			x = buf[i];
		if (mode & WR) {
			buf[i] = 'X';
		}
	}
	free(buf);
}

int main(int argc, char *argv[]) {
	size_t sz;
	size_t count;
	int mode;

	if (argc < 4) {
		fprintf(stderr, "usage: pgfault <sz> <count> <mode>\n");
		return 1;
	}
	sz = strtol(argv[1], NULL, 0);
	count = strtol(argv[2], NULL, 0);
	mode = strtol(argv[3], NULL, 0);

	for (int i = 0; i < count; ++i) {
		do_one(sz, mode);
	}
	return 0;
}
