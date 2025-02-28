#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage open-file <file>");
	}

	int fd = open(argv[1], O_RDONLY);
	printf("opened %s fd %d\n", argv[1], fd);
	sleep(3600);
}
