#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

#define M (1<<20)
#define G (1<<30)
#define PREALLOC G
#define CHUNK (100*M)

int main(int argc, char **argv) {
	int ret;
	int fd;
	char *buf;
	struct iovec iov;
	int iovcnt;
	unsigned int off;

	if (argc != 2) {
		fprintf(stderr, "usage: chunk-write <filename>\n");
		exit(1);
	}

	fd = open(argv[1], O_WRONLY | O_CREAT);
	if (fd == -1) {
		fprintf(stderr, "open failed: %d\n", errno);
		exit(errno);
	}

        ret = posix_fallocate(fd, 0, PREALLOC);
	if (ret) {
		fprintf(stderr, "fallocate failed: %d\n", ret);
		ret = errno;
		goto close;
	}

	buf = malloc(CHUNK);
	if (!buf) {
		fprintf(stderr, "malloc chunk failed\n");
		ret = ENOMEM;
		goto close;
	}


	iov.iov_base = buf;
	iovcnt = 1;
	off = 0;
	for (int i = 0; i < PREALLOC / CHUNK; ++i) {
		iov.iov_len = CHUNK;
		memset(buf, i % 256, CHUNK);
		while (iov.iov_len) {
			ret = pwritev(fd, &iov, iovcnt, off);
			if (ret == -1) {
				if (errno == -EINTR)
					continue;
				fprintf(stderr, "pwritev failed: %d\n", errno);
				ret = errno;
				goto free;
			}
			iov.iov_len -= ret;
			off += ret;
		}
	}

	ret = fsync(fd);
	if (ret) {
		fprintf(stderr, "fsync failed: %d\n", errno);
		ret = errno;
		goto free;
	}

	ret = 0;
free:
	free(buf);
close:
	close(fd);
	exit(ret);
}
