#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#define CHUNK_SZ (128 * 1024)

int main(int argc, char *argv[])
{
	int fd;
	struct stat st;
	char buf[CHUNK_SZ];
	off_t sz, off;
	ssize_t ret;
	unsigned int seed;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
		return 1;
	}

	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	if (fstat(fd, &st)) {
		perror("fstat");
		return 1;
	}
	sz = st.st_size;
	if (sz < CHUNK_SZ) {
		fprintf(stderr, "file too small\n");
		return 1;
	}

	seed = getpid();
	while (1) {
		off = ((off_t)rand_r(&seed) * rand_r(&seed)) % (sz - CHUNK_SZ);
		off &= ~4095ULL;
		ret = pread(fd, buf, CHUNK_SZ, off);
		if (ret < 0 && errno != EINTR) {
			perror("pread");
			return 1;
		}
	}
}
