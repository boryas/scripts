#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
	int fd;
	struct stat st;
	off_t sz;
	char *buf;
	int ret;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
		return 1;
	}

	fd = open(argv[1], O_RDONLY);
	if (fd == -1) {
		perror("open");
		return 1;
	}

	if (!fstat(fd, &st)) {
		sz = st.st_size;
	}

	buf = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
	if (buf == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	int parity = 0;
	while (1) {
		off_t roff = rand() % sz;
		parity |= (buf[roff] % 2);
	}
	printf("%d\n", parity);

	munmap(buf, sz);
	close(fd);

	return 0;
}
