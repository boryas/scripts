#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

size_t blksize(int fd) {
	struct stat st;
	if (fstat(fd, &st)) {
		fprintf(stderr, "failed to stat fd for block size. %d\n", errno);
		return 4096;
	}
	return st.st_blksize;
}

int read_full(int fd, char *buf, size_t sz) {
	int ret;
	int bytes_read = 0;
	while (sz > 0) {
		ret = read(fd, buf, sz);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "read_full failed: %d\n", errno);
			return -errno;
		} else if (ret == 0) {
			break;
		} else {
			sz -= ret;
			bytes_read += ret;
			buf += ret;
		}
	}
	return bytes_read;
}

int write_full(int fd, char *buf, size_t sz) {
	int ret;
	int bytes_written = 0;

	while (sz > 0) {
		ret = write(fd, buf, sz);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "write_full failed: %d\n", errno);
			return -errno;
		} else if (ret == 0) {
			break;
		} else {
			sz -= ret;
			bytes_written += ret;
			buf += ret;
		}
	}
	return bytes_written;
}

int create_hole(int fd, size_t sz) {
	off_t file_end = lseek(fd, sz, SEEK_CUR);
	int ret;

	if (file_end < 0)
		return -errno;

	return 0;

	if (file_end - sz >= 0 && sz >= 0) {
		ret = fallocate(
			fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, file_end - sz, sz);
		if (ret < 0) {
			fprintf(stderr, "hole punch %lu %lu failed: %d\n", file_end, sz, errno);
			return -errno;
		}
	}
	return 0;
}

int is_null(char *buf, size_t sz) {
	size_t step = 32;
	for (int i = 0; i < step; ++i) {
		if (sz <= i)
			return 1;
		if (buf[i] != 0)
			return 0;
	}

	return !memcmp(buf, buf + step, sz - step);
}

int sparse_write(int fd, char *buf, size_t sz) {
	int ret;

	if (is_null(buf, sz)) {
		ret = create_hole(fd, sz);
	} else {
		ret = write_full(fd, buf, sz);
	}
	return ret;
}

int copy(int infd, int outfd) {
	char *buf;
	const size_t sz = blksize(outfd);
	int written = 0;
	int ret;

	buf = malloc(sz);
	if (!buf) {
		fprintf(stderr, "failed to allocate buffer\n");
		return -ENOMEM;
	}

	while (1) {
		ret = read_full(infd, buf, sz);
		if (ret < 0)
			goto free;
		if (ret == 0)
			break;

		ret = sparse_write(outfd, buf, ret);
		if (ret < 0)
			goto free;
		written += ret;
	}

	ret = written;
free:
	free(buf);
	return ret;
}

int main(int argc, char **argv) {

	if (argc < 3) {
		fprintf(stderr, "usage: holepunch-write <infile> <ofile>\n");
		exit(-22);
	}

	char *fin = argv[1];
	char *fout = argv[2];

	int infd = open(fin, O_RDONLY);
	if (infd < 0) {
		fprintf(stderr, "failed to open infile %s: %d\n", fin, errno);
	}
	int outfd = open(fout, O_CREAT | O_TRUNC | O_WRONLY, 0644);
	if (outfd < 0) {
		fprintf(stderr, "failed to open ofile %s: %d\n", fout, errno);
	}

	int ret = copy(infd, outfd);
	printf("copied %d bytes!\n", ret);
}
