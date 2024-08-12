#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <stddef.h>
#include <sys/types.h>

ssize_t do_write(int fd, const char *buf, ssize_t len) {
	ssize_t ret = 0;
	loff_t off = 0;
	while (off < len) {
		ret = pwrite(fd, buf, len, off);
		if (ret == -1) { if (errno == EINTR)
				continue;
			fprintf(stderr, "write failed: %d\n", errno);
			return -errno;
		}
		off += ret;
		buf += ret;
	}
	return ret;
}

char *get_tmp_template(const char *dir) {
	static const char *suffix = ".XXXXXX";
	size_t in_len = strlen(dir);
	size_t out_len = in_len + strlen(suffix);
	char *out;

	out = malloc(out_len + 1);
	if (!out) {
		fprintf(stderr, "failed to allocate buffer for tmp filename template\n");
		return NULL;
	}
	strcpy(out, dir);
	strcat(out, suffix);
	return out;
}

int atomic_update_file(const char *filename, const char *buf, ssize_t len) {
	int fd_tmp, fd_parent;
	int ret;
	char *dup_filename, *parent_filename;
	char *tmp_filename;

	dup_filename = strdup(filename);
	if (!dup_filename) {
		fprintf(stderr, "strdup failed: %d\n", errno);
		ret = -errno;
		goto out;
	}
	parent_filename = dirname(dup_filename);

	tmp_filename = get_tmp_template(filename);
	if (!tmp_filename) {
		ret = -ENOMEM;
		goto out_free_dup;
	}

	fd_tmp = mkstemp(tmp_filename);
	if (fd_tmp == -1) {
		fprintf(stderr, "mkstemp failed: %d\n", errno);
		ret = -errno;
		goto out_free_tmp;
	}

	fd_parent = open(parent_filename, O_RDONLY);
	if (fd_parent == -1) {
		fprintf(stderr, "open parent %s failed: %d\n", parent_filename, errno);
		ret = -errno;
		goto out_close_tmp;
	}

	ret = do_write(fd_tmp, buf, len);
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
		fprintf(stderr, "rename %s->%s failed: %d\n", tmp_filename, filename, errno);
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
out_free_tmp:
	free(tmp_filename);
out_free_dup:
	free(dup_filename);
out:
	return ret;
}

#define SZ 40960
char buf[SZ];

int main(int argc, char **argv) {
	char *fname;

	if (argc < 2) {
		fprintf(stderr, "usage: atomic-update <file>");
		return -22;
	}
	fname = argv[1];
	memset(buf, 0, SZ);
	return atomic_update_file(fname, buf, SZ);
}
