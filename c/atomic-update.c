#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

ssize_t do_write(int fd, const char *buf, ssize_t len) {
	ssize_t ret = 0;
	loff_t off = 0;
	while (off < len) {
		ret = pwrite(fd, buf, len, off);
		if (ret == -1) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "write failed: %d\n", errno);
			return -errno;
		}
		off += ret;
		buf += ret;
	}
	return ret;
}

int atomic_update_file(const char *filename, const char *new_content) {
	char tmp_filename[] = "tmpfileXXXXXX";
	int fd_tmp, fd_parent;
	int ret;
	int len = strlen(new_content);

	char *parent_filename = strdup(filename);
	if (!parent_filename) {
		fprintf(stderr, "strdup failed: %d\n", errno);
		ret = -errno;
		goto out;
	}

	fd_tmp = mkstemp(tmp_filename);
	if (fd_tmp == -1) {
		fprintf(stderr, "mkstemp failed: %d\n", errno);
		ret = -errno;
		goto out;
	}

	fd_parent = open(parent_filename, O_WRONLY);
	if (fd_parent == -1) {
		fprintf(stderr, "open parent failed: %d\n", errno);
		ret = -errno;
		goto out_close_tmp;
	}

	ret = do_write(fd_tmp, new_content, len);
	if (ret < 0)
		goto out_unlink_tmp;

        // Flush the file contents to disk
	ret = fsync(fd_tmp);
	if (ret) {
		fprintf(stderr, "fsync tmpfile failed: %d\n", errno);
		ret = -errno;
		goto out_unlink_tmp;
	}

	// Rename the tmp file to the target file
	ret = rename(tmp_filename, filename);
	if (ret) {
		fprintf(stderr, "rename tmpfile->filename failed: %d\n", errno);
		ret = -errno;
		goto out_unlink_tmp;
	}

	ret = fsync(fd_parent);
	if (ret) {
		fprintf(stderr, "fsync parent failed: %d\n", errno);
		ret = -errno;
		goto out_close_parent;
	}

out_unlink_tmp:
	unlink(tmp_filename);
out_close_parent:
	close(fd_parent);
out_close_tmp:
	close(fd_tmp);
out:
	return ret;
}

int main(int argc, char **argv) {
}
