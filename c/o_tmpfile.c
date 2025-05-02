#define _GNU_SOURCE 1
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

int main() {
	int fd = open(".", O_TMPFILE | O_RDWR, S_IRUSR | S_IWUSR);
	printf("opened %d\n", fd);
	int ret = fsync(fd);
	if (ret) {
		fprintf(stderr, "fsync failed: %s\n", strerror(errno));
	}
	ret = linkat(fd, "", AT_FDCWD, "my-dumb-o-tmpfile", AT_EMPTY_PATH);
	if (ret) {
		fprintf(stderr, "linkat failed: %s\n", strerror(errno));
	}
}
