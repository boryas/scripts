#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#define BUF_SZ (128 * (1 << 10UL))

int read_once(int fd, size_t sz) {
	char buf[BUF_SZ];
	size_t rd = 0;
	int ret = 0;

	while (rd < sz) {
		ret = read(fd, buf, BUF_SZ);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "read failed: %d\n", errno);
			return -errno;
		} else if (ret == 0) {
			break;
		} else {
			rd += ret;
		}
	}
	return rd;
}

int read_loop(char *fname) {
	int fd;
	struct stat st;
	size_t sz = 0;
	int ret;

	while (1) {
		fd = open(fname, O_RDONLY);
		if (fd == -1) {
			perror("open");
			return 1;
		}
		if (!sz) {
			if (!fstat(fd, &st)) {
				sz = st.st_size;
			} else {
				perror("stat");
				return 1;
			}
		}

                ret = read_once(fd, sz);
		close(fd);
	}
}

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

	return read_loop(argv[1]);
}
