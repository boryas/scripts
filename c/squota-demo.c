#include <linux/btrfs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include <linux/btrfs_tree.h>
#include <sys/ioctl.h>
#include <sys/types.h>

static char *btrfs = "/mnt/lol/";
static char *snap_src = "/mnt/lol/src/";
static char *snap_name = "snap";
static char *nested_subv = "/mnt/lol/snap/subv";
static char *snap_f = "/mnt/lol/snap/f";
static char *nested_subv_f = "/mnt/lol/snap/subv/f";

int open_dir(char *path, DIR **dir, int *fd)
{
	*dir = opendir(path);
	if (!*dir) {
		fprintf(stderr, "failed to open dir %s %d\n", path, errno);
		return -errno;
	}
	*fd = dirfd(*dir);
	if (*fd < 0) {
		fprintf(stderr, "failed to get dir fd %d\n", errno);
		closedir(*dir);
		return -errno;
	}
	return 0;
}

int btrfs_set_qgroup_limit(char *path, uint64_t qgid, uint64_t limit)
{
	DIR *dir;
	int fd;
	int ret;
	struct btrfs_ioctl_qgroup_limit_args args = {
		.qgroupid = qgid,
		.lim = {
			.flags = BTRFS_QGROUP_LIMIT_MAX_EXCL,
			.max_excl = limit
		},
	};

	ret = open_dir(path, &dir, &fd);
	if (ret)
		goto out;

	ret = ioctl(fd, BTRFS_IOC_QGROUP_LIMIT, &args);
	if (ret)
		fprintf(stderr, "qgroup limit failed %llu %llu %d\n", qgid, limit, ret);
out:
	closedir(dir);
	return ret;
}


int btrfs_create_qgroup(char *path, uint64_t qgid)
{
	DIR *dir;
	int fd;
	struct btrfs_ioctl_qgroup_create_args args = {
		.create = 1,
		.qgroupid = qgid
	};
	int ret;

	ret = open_dir(path, &dir, &fd);
	if (ret)
		goto out;

	ret = ioctl(fd, BTRFS_IOC_QGROUP_CREATE, &args);
	if (ret)
		fprintf(stderr, "qgroup create failed %llu %d\n", qgid, ret);

	closedir(dir);
out:
	return ret;
}

size_t inherit_sz(size_t count)
{
	struct btrfs_qgroup_inherit inherit;

	return sizeof(inherit) + sizeof(inherit.qgroups[0]) * count;
}

struct btrfs_qgroup_inherit *prep_inherit(size_t count, uint64_t *qgids)
{
	struct btrfs_qgroup_inherit *inherit;

	inherit = calloc(inherit_sz(count), 1);
	if (!inherit) {
		fprintf(stderr, "failed to allocate qg inherit struct count %lu\n", count);
		return NULL;
	}
	inherit->num_qgroups = count;
	for (int i = 0; i < count; ++i)
		inherit->qgroups[i] = qgids[i];
	return inherit;
}

int btrfs_snapshot(char *src, char *dst, char *name, uint64_t qgid)
{
	int ret;
	DIR *src_dir;
	int src_fd;
	DIR *dst_dir;
	int dst_fd;
	struct btrfs_ioctl_vol_args_v2	args;
	struct btrfs_qgroup_inherit *inherit;
	int name_len = strlen(name);

	ret = open_dir(src, &src_dir, &src_fd);
	if (ret)
		goto out;
	ret = open_dir(dst, &dst_dir, &dst_fd);
	if (ret)
		goto close_src_dir;

	inherit = prep_inherit(1, &qgid);
	if (!inherit) {
		ret = -ENOMEM;
		goto close_dst_dir;
	}

	printf("create snapshot src %s dst %s name %s\n", src, dst, name);
	memset(&args, 0, sizeof(args));
	args.fd = src_fd;
	strncpy(args.name, name, name_len + 1);
	args.name[name_len] = '\0';
	args.flags |= BTRFS_SUBVOL_QGROUP_INHERIT;
	args.size = inherit_sz(1);
	args.qgroup_inherit = inherit;
	ret = ioctl(dst_fd, BTRFS_IOC_SNAP_CREATE_V2, &args);
	if (ret)
		fprintf(stderr, "snap ioctl failed %d\n", ret);

free_inherit:
	free(inherit);
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

int main(int argc, char **argv)
{
	int ret;
	/* qgid for qg 1/100 */
	uint64_t qgid = 1UL << 48 | 100UL;
	/* 10MiB */
	uint64_t limit = 10UL * (1UL << 20);

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

	ret = btrfs_create_qgroup(btrfs, qgid);
	if (ret)
		exit(ret);

	ret = btrfs_set_qgroup_limit(btrfs, qgid, limit);
	if (ret)
		exit(ret);

	ret = btrfs_snapshot(snap_src, btrfs, snap_name, qgid);
	if (ret)
		exit(ret);

	exit(0);
}
