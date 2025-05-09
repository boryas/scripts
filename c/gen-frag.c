#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

int do_sync(const char *directory) {
	int ret;
	int fd = open(directory, O_WRONLY);
	if (fd < 0)
	  return fd;
	ret = syncfs(fd);
	return ret;
}

int create_files(const char *directory, int num_files) {
	char file_path[256];
	FILE *fp;
	int ret;

	// Create the specified number of files
	for (int i = 0; i < num_files; i++) {
	  snprintf(file_path, sizeof(file_path), "%s/frag.%d.txt", directory, i + 1);

          fp = fopen(file_path, "w");
          if (!fp) {
		  perror("Error creating file");
		  return -errno;
          }

          char buffer[4096] = {0};
          int ret = fwrite(buffer, sizeof(char), 4096, fp);
          if (ret < 4096)
		  return -errno;

          fclose(fp);
        }

	printf("Created %d files in directory: %s\n", num_files, directory);
	return 0;
}

int delete_half(const char *directory, int num_files) {
	char file_path[256];

	// Delete half of the files
	for (int i = 0; i < num_files / 2; i++) {
		snprintf(file_path, sizeof(file_path), "%s/frag.%d.txt", directory, i * 2);
		if (remove(file_path) != 0) {
			perror("Error deleting file");
			return -errno;
		}
	}

	printf("Deleted %d files in directory: %s\n", num_files / 2, directory);
	return 0;
}

int main(int argc, char *argv[]) {
	if (argc != 3) {
		fprintf(stderr, "Usage: %s <directory> <number_of_files>\n", argv[0]);
		return 1;
	}

        const char *directory = argv[1];
        int num_files = atoi(argv[2]);

        if (num_files <= 0) {
		fprintf(stderr, "Please specify a valid number of files.\n");
		return 1;
	}

	create_files(directory, num_files);
	do_sync(directory);
	delete_half(directory, num_files);
	do_sync(directory);

	return 0;
}
