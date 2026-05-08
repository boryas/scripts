/*
 * Create files with data, hold them open, and optionally do continuous
 * scatter reads across them to keep extent_tree.lock held on many inodes
 * simultaneously.
 *
 * Phase 1 (create): creates <dir>/0..<count-1> with 4K data each.
 * Phase 2 (hold): sits with all fds open, preventing inode eviction.
 *                 If scatter_readers > 0, spawns threads that randomly
 *                 read from the held files, causing tree->lock contention.
 *
 * If hold_fraction < 1.0 (via 4th arg as percent, default 100),
 * only that fraction of fds are held open; the rest are closed after
 * reading, leaving their inodes on the LRU for kswapd to reclaim
 * through btrfs_del_inode_from_root() → xa_lock.
 *
 * Usage: hold-inodes <dir> <count> [scatter_readers] [hold_pct]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile int running = 1;
static int *g_fds;
static int g_count;

static void handler(int sig) { (void)sig; running = 0; }

static void *scatter_reader(void *arg)
{
	(void)arg;
	char buf[4096];
	unsigned int seed = (unsigned int)(unsigned long)arg;

	while (running) {
		int idx = rand_r(&seed) % g_count;
		if (g_fds[idx] >= 0) {
			pread(g_fds[idx], buf, sizeof(buf), 0);
		}
	}
	return NULL;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <dir> <count> [scatter_readers]\n", argv[0]);
		return 1;
	}

	const char *dir = argv[1];
	int count = atoi(argv[2]);
	int nr_scatter = argc > 3 ? atoi(argv[3]) : 0;
	int hold_pct = argc > 4 ? atoi(argv[4]) : 100;

	if (count <= 0) {
		fprintf(stderr, "count must be > 0\n");
		return 1;
	}
	if (hold_pct < 1 || hold_pct > 100)
		hold_pct = 100;

	struct rlimit rl;
	rl.rlim_cur = count + 256;
	rl.rlim_max = count + 256;
	if (setrlimit(RLIMIT_NOFILE, &rl) < 0) {
		perror("setrlimit NOFILE");
		return 1;
	}

	g_fds = calloc(count, sizeof(int));
	if (!g_fds) {
		perror("calloc");
		return 1;
	}
	g_count = count;
	for (int i = 0; i < count; i++)
		g_fds[i] = -1;

	mkdir(dir, 0755);

	char path[4096];
	int opened = 0, held = 0, closed = 0;

	for (int i = 0; i < count; i++) {
		snprintf(path, sizeof(path), "%s/%d", dir, i);

		g_fds[i] = open(path, O_CREAT | O_RDWR, 0644);
		if (g_fds[i] < 0) {
			if (errno == EMFILE || errno == ENFILE) {
				fprintf(stderr, "hold-inodes: fd limit at %d\n", i);
				break;
			}
			continue;
		}

		opened++;

		/*
		 * Close some fds so their inodes go to the LRU as "unused"
		 * (i_count=0, nlink > 0). kswapd can reclaim these through
		 * btrfs_del_inode_from_root() → xa_lock.
		 */
		if ((i % 100) >= hold_pct) {
			close(g_fds[i]);
			g_fds[i] = -1;
			closed++;
		} else {
			held++;
		}

		if (opened % 20000 == 0)
			fprintf(stderr, "hold-inodes: opened %d / %d\n", opened, count);
	}

	if (opened > 0 && g_fds[0] >= 0)
		fsync(g_fds[0]);

	fprintf(stderr, "hold-inodes: created %d, holding %d, closed %d (LRU)", opened, held, closed);
	if (nr_scatter > 0)
		fprintf(stderr, ", %d scatter readers", nr_scatter);
	fprintf(stderr, ", waiting for signal\n");

	signal(SIGTERM, handler);
	signal(SIGINT, handler);

	/* Spawn scatter reader threads */
	pthread_t *threads = NULL;
	if (nr_scatter > 0) {
		threads = calloc(nr_scatter, sizeof(pthread_t));
		for (int i = 0; i < nr_scatter; i++)
			pthread_create(&threads[i], NULL, scatter_reader,
				       (void *)(unsigned long)(i + 1));
	}

	while (running)
		pause();

	if (threads) {
		for (int i = 0; i < nr_scatter; i++)
			pthread_join(threads[i], NULL);
		free(threads);
	}

	fprintf(stderr, "hold-inodes: closing %d fds\n", opened);
	for (int i = 0; i < count; i++) {
		if (g_fds[i] >= 0)
			close(g_fds[i]);
	}
	free(g_fds);
	return 0;
}
