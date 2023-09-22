#include <linux/btrfs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include <linux/btrfs_tree.h>
#include <sys/ioctl.h>
#include <sys/types.h>

int create_wrapper_qg(uint64_t qgid)
{
	return 0;
}

int set_qg_limit(uint64_t qgid)
{
	return 0;
}

int btrfs_snapshot(char *src, char *dst, uint64_t qgid)
{
	int ret;
	DIR *src_dir;
	int src_fd;
	DIR *dst_dir;
	int dst_fd;
	struct btrfs_ioctl_vol_args_v2	args;

	src_dir = opendir(src);
	if (!src_dir) {
		ret = -errno;
		goto out;
	}
	src_fd = dirfd(src_dir);
	if (src_fd < 0) {
		ret = -errno;
		goto close_src_dir;
	}

	dst_dir = opendir(dst);
	if (!dst_dir) {
		ret = -errno;
		goto close_src_dir;
	}
	dst_fd = dirfd(dst_dir);
	if (dst_fd < 0) {
		ret = -errno;
		goto close_dst_dir;
	}

	args.fd = src_fd;
	ret = ioctl(dst_fd, BTRFS_IOC_SNAP_CREATE_V2, &args);

close_dst_dir:
	closedir(dst_dir);
close_src_dir:
	closedir(src_dir);
out:
	return ret;
}

int btrfs_mksubvol(char *subv)
{
	return 0;
}

/* write bcnt blocks of size bs to f. All set to byte. */
int do_write(char *f, size_t bs, size_t bcnt, uint8_t byte)
{
	return 0;
}

static char *btrfs = "/mnt/lol";
static char *snap_src = "/mnt/lol/src";
static char *snap_dst = "/mnt/lol/snap";
static char *nested_subv = "/mnt/lol/snap/subv";
static char *snap_f = "/mnt/lol/snap/f";
static char *nested_subv_f = "/mnt/lol/snap/subv/f";

int main(int argc, char **argv)
{
	int ret;
	char *btrfs;
	char *snap;
	char *inner_subv;
	uint64_t qgid = 1UL << 48 | 100UL;

	/*
	if (argc != 2) {
		fprintf(stderr, "usage: squota-demo <btrfs-fs>");
		exit(-22);
	}
	 * inputs/preconditions:
	 * - btrfs (arg1)
	 * - squota enabled on btrfs
	 * - snapshot source subvol in that btrfs at /src
	 *
	 * steps:
	 * - create a wrapper qg
	 * - set a limit on it
	 * - snap the source, inheriting into that qg
	 * - create a nested subvol inside the snap
	 * - write in a mix to outer and inner till we hit the limit
	 */

	ret = btrfs_snapshot(snap_src, snap_dst, qgid);
	if (ret) {
		fprintf(stderr, "snapshot failed, %d\n", ret);
		exit(1);
	}

	exit(0);
}
