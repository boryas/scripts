#include <linux/btrfs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include <linux/btrfs.h>
#include <linux/btrfs_tree.h>
#include <sys/ioctl.h>
#include <sys/types.h>

static char *btrfs = "/mnt/lol/";
static char *snap_src = "/mnt/lol/src/";
static char *snap_name = "snap";
static char *subv_name = "subv";
static char *snap_d = "/mnt/lol/snap/";
static char *snap_f = "/mnt/lol/snap/f";
static char *nested_subv_f = "/mnt/lol/snap/subv/f";

struct qg_list;
struct qgroup;

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

int btrfs_set_qgroup_limit(int btrfs_fd, uint64_t qgid, uint64_t limit)
{
	int ret;
	struct btrfs_ioctl_qgroup_limit_args args = {
		.qgroupid = qgid,
		.lim = {
			.flags = BTRFS_QGROUP_LIMIT_MAX_EXCL,
			.max_excl = limit
		},
	};

	ret = ioctl(btrfs_fd, BTRFS_IOC_QGROUP_LIMIT, &args);
	if (ret)
		fprintf(stderr, "qgroup limit failed %llu %llu %d\n", qgid, limit, ret);
	return ret;
}


int create_qgroup(int btrfs_fd, uint64_t qgid, int create)
{
	struct btrfs_ioctl_qgroup_create_args args = {
		.create = create,
		.qgroupid = qgid
	};
	int ret;

	ret = ioctl(btrfs_fd, BTRFS_IOC_QGROUP_CREATE, &args);
	if (ret)
		fprintf(stderr, "qgroup %s failed %llu %d\n", create ? "create" : "destroy", qgid, ret);

	return ret;
}

int btrfs_create_qgroup(int btrfs_fd, uint64_t qgid)
{
	return create_qgroup(btrfs_fd, qgid, 1);
}

int btrfs_destroy_qgroup(int btrfs_fd, uint64_t qgid)
{
	return create_qgroup(btrfs_fd, qgid, 0);
}

int btrfs_assign_qgroup(int btrfs_fd, uint64_t child, uint64_t parent)
{
	int ret = 0;
	struct btrfs_ioctl_qgroup_assign_args args = {
		.assign = 1,
		.src = child,
		.dst = parent,
	};
	ret = ioctl(btrfs_fd, BTRFS_IOC_QGROUP_ASSIGN, &args);
	if (ret)
		fprintf(stdout, "failed to assign qgroup %llu to %llu %d\n", child, parent, ret);
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

int btrfs_create_subvolume(char *dst, char *name, uint64_t qgid)
{
	DIR *dst_dir;
	int dst_fd;
	struct btrfs_qgroup_inherit *inherit = NULL;
	struct btrfs_ioctl_vol_args_v2	args;
	int name_len = strlen(name);
	int ret;

	ret = open_dir(dst, &dst_dir, &dst_fd);
	if (ret)
		goto out;

	if (qgid) {
		inherit = prep_inherit(1, &qgid);
		if (!inherit) {
			ret = -ENOMEM;
			goto close_dst_dir;
		}
	}
	fprintf(stdout, "create subvol dst %s name %s\n", dst, name);
	memset(&args, 0, sizeof(args));
	strncpy(args.name, name, name_len + 1);
	args.name[name_len] = '\0';
	if (qgid && inherit) {
		args.flags |= BTRFS_SUBVOL_QGROUP_INHERIT;
		args.size = inherit_sz(1);
		args.qgroup_inherit = inherit;
	}
	ret = ioctl(dst_fd, BTRFS_IOC_SUBVOL_CREATE_V2, &args);
	if (ret)
		fprintf(stderr, "subvol create ioctl failed %d\n", ret);

	if (inherit)
		free(inherit);
close_dst_dir:
	closedir(dst_dir);
out:
	return ret;
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

	fprintf(stdout, "create snapshot src %s dst %s name %s\n", src, dst, name);
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

	free(inherit);
close_dst_dir:
	closedir(dst_dir);
close_src_dir:
	closedir(src_dir);
out:
	return ret;
}

int btrfs_sync(int btrfs_fd)
{
	int ret;

	ret = ioctl(btrfs_fd, BTRFS_IOC_SYNC, NULL);
	if (ret < 0)
		return -errno;
	return 0;
}


struct qg_list {
	struct qgroup *qg;
	struct qg_list *next;
};

void free_qgroup(struct qgroup *qg);
void free_qg_list(struct qg_list *qgs)
{
	struct qg_list *cur;
	while (qgs) {
		free_qgroup(qgs->qg);
		cur = qgs;
		qgs = qgs->next;
		free(cur);
	}
}

struct qg_list *push_qg(struct qgroup *qg, struct qg_list *head)
{
	struct qg_list *ins;

	ins = calloc(sizeof(*ins), 1);
	if (!ins)
		return ins;

	ins->qg = qg;
	ins->next = head;
	return ins;
}

struct qgroup {
	uint64_t qgid;
	uint64_t used;
	uint64_t limit;
	struct qg_list *parents;
	struct qg_list *children;
};

struct qgroup *alloc_qgroup(uint64_t qgid)
{
	struct qgroup *qg;

	qg = calloc(sizeof(*qg), 1);
	if (!qg)
		return qg;
	qg->qgid = qgid;
}

void free_qgroup(struct qgroup *qg) {
	if (!qg)
		return;
	free_qg_list(qg->parents);
	free_qg_list(qg->children);
	free(qg);
}

void dump_qgroup_helper(const struct qgroup *qg, int depth);
void dump_qg_list(const struct qg_list *qgs, int depth) {
	if (!qgs)
		return;
	while (qgs) {
		dump_qgroup_helper(qgs->qg, depth);
		qgs = qgs->next;
	}
}

void dump_qgroup_helper(const struct qgroup *qg, int depth) {
	int tabs = depth;

	while (tabs--)
		fprintf(stdout, "\t");

	fprintf(stdout, "Qgroup %llu. usage %llu/%llu\n", qg->qgid, qg->used, qg->limit ? qg->limit : -1);

	if (qg->parents) {
		dump_qg_list(qg->parents, depth+1);
	} else if (qg->children) {
		dump_qg_list(qg->children, depth+1);
	}
}

void dump_qgroup(const struct qgroup *qg) {
	dump_qgroup_helper(qg, 0);
};

int valid_key(const struct btrfs_key *key, const struct btrfs_ioctl_search_key *sk)
{
	if (key->objectid < sk->min_objectid ||
	    key->objectid > sk->max_objectid)
		return 0;

	if (key->type < sk->min_type ||
	    key->type > sk->max_type)
		return 0;

	if (key->offset < sk->min_offset ||
	    key->offset > sk->max_offset)
		return 0;

	return 1;
}

int qgroup_search(int btrfs_fd, struct btrfs_ioctl_search_args *args,
		  int (*fn)(const struct btrfs_ioctl_search_args *,
			    const struct btrfs_key *, uint64_t off,
			    void *data),
		  void *data)
{
	struct btrfs_ioctl_search_header *shdr;
	struct btrfs_key key;
	int i;
	int ret;

	args->key.nr_items = 4096;
	ret = ioctl(btrfs_fd, BTRFS_IOC_TREE_SEARCH, args);
	if (ret < 0) {
		fprintf(stderr, "failed to lookup qgroup items\n");
		ret = -errno;
		goto out;
	}
	if (!args->key.nr_items) {
		ret = 1;
		goto out;
	}
	size_t off = 0;
	for (i = 0; i < args->key.nr_items; ++i) {
		shdr = (struct btrfs_ioctl_search_header *)(args->buf + off);
		off += sizeof(*shdr);
		key.objectid = shdr->objectid;
		key.type = shdr->type;
		key.offset = shdr->offset;
		if (!valid_key(&key, &args->key))
			goto next;
		ret = fn(args, &key, off, data);
		if (ret)
			goto out;
next:
		off += shdr->len;
	}
	ret = 0;
out:
	return ret;
}

int print_qgroup_item(const struct btrfs_ioctl_search_args *args,
		      const struct btrfs_key *k,
		      uint64_t off, void *data)
{
	switch(k->type) {
	case BTRFS_QGROUP_INFO_KEY:
		fprintf(stdout, "qgroup info %u/%llu!\n", k->offset >> 48, (k->offset << 48) >> 48);
		break;
	case BTRFS_QGROUP_LIMIT_KEY:
		fprintf(stdout, "qgroup limit %u/%llu!\n", k->offset >> 48, (k->offset << 48) >> 48);
		break;
	case BTRFS_QGROUP_RELATION_KEY:
		fprintf(stdout, "qgroup limit %u/%llu : %u/%llu!\n",
			k->objectid >> 48, (k->objectid << 48) >> 48,
			k->offset >> 48, (k->offset << 48) >> 48);
		break;
	default:
		break;
	}
	return 0;
}

int add_qgroup_child(const struct btrfs_ioctl_search_args *args,
		     const struct btrfs_key *k,
		     uint64_t off, void *data) {
	struct qgroup *qg = data;
	struct qgroup *child;
	uint64_t qgid = k->objectid;
	uint64_t relation_qgid = k->offset;

	if (qgid <= relation_qgid)
		return 0;

	child = alloc_qgroup(relation_qgid);
	if (!child)
		return -ENOMEM;

	qg->children = push_qg(child, qg->children);
	if (!qg->children) {
		free(child);
		return -ENOMEM;
	}

	return 0;
}

int add_qgroup_parent(const struct btrfs_ioctl_search_args *args,
		      const struct btrfs_key *k,
		      uint64_t off, void *data) {
	struct qgroup *qg = data;
	struct qgroup *parent;
	uint64_t qgid = k->objectid;
	uint64_t relation_qgid = k->offset;

	if (qgid >= relation_qgid)
		return 0;

	parent = alloc_qgroup(relation_qgid);
	if (!parent)
		return -ENOMEM;

	qg->parents = push_qg(parent, qg->parents);
	if (!qg->parents) {
		free(parent);
		return -ENOMEM;
	}
	return 0;
}

int get_qgroup_stats(const struct btrfs_ioctl_search_args *args,
		     const struct btrfs_key *k,
		     uint64_t off, void *data) {
	struct qgroup *qg = data;
	struct btrfs_qgroup_info_item *qg_info;

	if (k->type != BTRFS_QGROUP_INFO_KEY)
		return -EUCLEAN;
	qg->qgid = k->offset;
	qg_info = (struct btrfs_qgroup_info_item *)(args->buf + off);
	qg->used = qg_info->excl;
	return 0;
}

int get_qgroup_limit(const struct btrfs_ioctl_search_args *args,
		     const struct btrfs_key *k,
		     uint64_t off, void *data) {
	struct qgroup *qg = data;
	struct btrfs_qgroup_limit_item *qg_limit;

	if (k->type != BTRFS_QGROUP_LIMIT_KEY)
		return -EUCLEAN;
	qg_limit = (struct btrfs_qgroup_limit_item *)(args->buf + off);
	qg->limit = qg_limit->max_excl;
	return 0;
}

int btrfs_list_qgs(int btrfs_fd, int32_t level)
{
	uint16_t qgid_level;
	uint64_t min_qgid;
	uint64_t max_qgid;
	struct btrfs_ioctl_search_args args = {
		.key = {
			.tree_id = BTRFS_QUOTA_TREE_OBJECTID,
			.min_type = BTRFS_QGROUP_INFO_KEY,
			.max_type = BTRFS_QGROUP_INFO_KEY,
			.max_transid = -1ULL,
			.nr_items = 4096,
		},
	};

	if (level >= 0) {
		qgid_level = level;
		min_qgid = (uint64_t)qgid_level << 48;
		max_qgid = min_qgid | -1ULL >> 48;
	} else {
		min_qgid = 0;
		max_qgid = -1ULL;
	}

	args.key.min_offset = min_qgid;
	args.key.max_offset = max_qgid;

	return qgroup_search(btrfs_fd, &args, &print_qgroup_item, NULL);
}

int btrfs_get_qgroup(int btrfs_fd, struct qgroup *qg, int recurse_direction)
{
	int ret;
	uint64_t qgid = qg->qgid;
	struct btrfs_ioctl_search_args args = {
		.key = {
			.tree_id = BTRFS_QUOTA_TREE_OBJECTID,
			.min_offset = qgid,
			.max_offset = qgid,
			.max_transid = -1ULL,
			.nr_items = 4096,
		},
	};
	struct qg_list *itr = NULL;

	/* info item */
	args.key.min_type = BTRFS_QGROUP_INFO_KEY,
	args.key.max_type = BTRFS_QGROUP_INFO_KEY,
	ret = qgroup_search(btrfs_fd, &args, &get_qgroup_stats, qg);
	if (ret) {
		if (ret > 0)
			fprintf(stderr, "Qgroup %llu not found!\n", qg->qgid);
		return ret;
	}

	/* limit item */
	args.key.min_type = BTRFS_QGROUP_LIMIT_KEY,
	args.key.max_type = BTRFS_QGROUP_LIMIT_KEY,
	ret = qgroup_search(btrfs_fd, &args, &get_qgroup_limit, qg);
	if (ret)
		return ret;

	if (!recurse_direction)
		return ret;

	args.key.min_objectid = qgid;
	args.key.max_objectid = qgid;
	args.key.min_type = BTRFS_QGROUP_RELATION_KEY;
	args.key.max_type = BTRFS_QGROUP_RELATION_KEY;

	/* parent relation items */
	if (recurse_direction > 0) {
		args.key.min_offset = qgid + 1,
		args.key.max_offset = -1ULL,
		ret = qgroup_search(btrfs_fd, &args, &add_qgroup_parent, qg);
		if (ret > 0)
			ret = 0;
		if (ret < 0)
			return ret;
		itr = qg->parents;
	} else if (recurse_direction < 0) {
		/* child relation items */
		args.key.min_offset = 0,
		args.key.max_offset = qgid - 1,
		ret = qgroup_search(btrfs_fd, &args, &add_qgroup_child, qg);
		if (ret > 0)
			ret = 0;
		if (ret < 0)
			return ret;
		itr = qg->children;
	}

	while (itr) {
		ret = btrfs_get_qgroup(btrfs_fd, itr->qg, recurse_direction);
		if (ret)
		{
			printf("recurse to %llu failed %d\n", itr->qg->qgid, ret);
			return ret;
		}
		itr = itr->next;
	}

	return ret;
}

/* write bcnt blocks of size bs to f. All set to byte. */
int do_write(char *f, size_t bs, size_t bcnt, uint8_t byte)
{
	return 0;
}

int main(int argc, char **argv)
{
	int ret;
	uint64_t qgid1 = 1UL << 48 | 100UL;
	uint64_t qgid2 = 2UL << 48 | 100UL;
	uint64_t limit = 10UL * (1UL << 20);
	struct qgroup *qg;
	int btrfs_fd;
	DIR *btrfs_dir;

	ret = open_dir(btrfs, &btrfs_dir, &btrfs_fd);
	if (ret)
		goto out;

	/* create 1/100 */
	ret = btrfs_create_qgroup(btrfs_fd, qgid1);
	if (ret)
		goto close_dir;

	ret = btrfs_create_qgroup(btrfs_fd, qgid2);
	if (ret)
		goto close_dir;

	ret = btrfs_assign_qgroup(btrfs_fd, qgid1, qgid2);
	if (ret)
		goto close_dir;

	/* limit it to 10MiB */
	ret = btrfs_set_qgroup_limit(btrfs_fd, qgid1, limit);
	if (ret)
		goto close_dir;

	/* /mnt/lol/src -> /mnt/lol/snap; explicit inherit */
	ret = btrfs_snapshot(snap_src, btrfs, snap_name, qgid1);
	if (ret)
		goto close_dir;

	/* /mnt/lol/subv; explicit inherit */
	ret = btrfs_create_subvolume(btrfs, subv_name, qgid1);
	if (ret)
		goto close_dir;

	/* /mnt/lol/snap/subv; auto inherit */
	ret = btrfs_create_subvolume(snap_d, subv_name, 0);
	if (ret)
		goto close_dir;

	/* read the qg tree under 2/100 */
	qg = alloc_qgroup(qgid2);
	if (!qg) {
		ret = -ENOMEM;
		goto close_dir;
	}
	qg->qgid = qgid2;
	ret = btrfs_get_qgroup(btrfs_fd, qg, -1);
	if (ret) {
		if (ret > 0) {
			ret = 0;
		}
		goto free_qg;
	}

	dump_qgroup(qg);

	ret = btrfs_list_qgs(btrfs_fd, 0);
	if (ret) {
		goto free_qg;
	}
	ret = btrfs_list_qgs(btrfs_fd, 1);
	if (ret) {
		goto free_qg;
	}
	ret = btrfs_list_qgs(btrfs_fd, 2);
	if (ret) {
		goto free_qg;
	}
	ret = btrfs_list_qgs(btrfs_fd, 3);
	if (ret <= 0) {
		if (ret == 0)
			fprintf(stderr, "lookup 3/X qgs actually found something!?\n");
		goto free_qg;
	}
	ret = btrfs_list_qgs(btrfs_fd, -1);
	if (ret) {
		goto free_qg;
	}

	ret = 0;
free_qg:
	free_qgroup(qg);
close_dir:
	closedir(btrfs_dir);
out:
	exit(ret);
}
