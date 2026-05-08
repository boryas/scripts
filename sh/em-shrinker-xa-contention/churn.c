/*
 * Fast file create/unlink churn to hammer btrfs_add_inode_to_root()
 * and btrfs_del_inode_from_root(), both of which need xa_lock.
 *
 * Usage: churn <dir> <nworkers> [duration_sec]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile int running = 1;

static void handler(int sig) { (void)sig; running = 0; }

struct worker_ctx {
	const char *dir;
	int id;
	unsigned long ops;
};

static void *worker(void *arg)
{
	struct worker_ctx *ctx = arg;
	char path[4096];
	int seq = 0;

	snprintf(path, sizeof(path), "%s/w%d", ctx->dir, ctx->id);
	mkdir(path, 0755);

	while (running) {
		char fpath[4096];
		snprintf(fpath, sizeof(fpath), "%s/%d", path, seq % 500);

		int fd = open(fpath, O_CREAT | O_WRONLY, 0644);
		if (fd >= 0) {
			write(fd, "x", 1);
			close(fd);
		}
		unlink(fpath);
		seq++;
		ctx->ops++;
	}
	return NULL;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <dir> <nworkers> [duration_sec]\n", argv[0]);
		return 1;
	}

	const char *dir = argv[1];
	int nworkers = atoi(argv[2]);
	int duration = argc > 3 ? atoi(argv[3]) : 0;

	if (nworkers <= 0 || nworkers > 256) {
		fprintf(stderr, "nworkers must be 1..256\n");
		return 1;
	}

	mkdir(dir, 0755);

	signal(SIGTERM, handler);
	signal(SIGINT, handler);

	struct worker_ctx *ctxs = calloc(nworkers, sizeof(*ctxs));
	pthread_t *threads = calloc(nworkers, sizeof(*threads));

	for (int i = 0; i < nworkers; i++) {
		ctxs[i].dir = dir;
		ctxs[i].id = i;
		ctxs[i].ops = 0;
		pthread_create(&threads[i], NULL, worker, &ctxs[i]);
	}

	if (duration > 0) {
		sleep(duration);
		running = 0;
	} else {
		while (running)
			pause();
	}

	unsigned long total = 0;
	for (int i = 0; i < nworkers; i++) {
		pthread_join(threads[i], NULL);
		total += ctxs[i].ops;
	}

	fprintf(stderr, "churn: %d workers, %lu total ops (%.0f ops/sec)\n",
		nworkers, total, duration > 0 ? (double)total / duration : 0.0);

	free(ctxs);
	free(threads);
	return 0;
}
