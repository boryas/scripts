#!/usr/bin/env bash
# Reproducer: btrfs EM shrinker xa_lock contention (PREEMPT_NONE).
#
# find_first_inode_to_shrink() holds root->inodes.xa_lock for an entire
# scheduler timeslice (~2.8ms on 8 CPUs) while iterating inodes, because
# cond_resched_lock() + spin_needbreak()=0 only drops at tick boundaries.
#
# Creates 200k empty files (populates the xarray with empty extent map
# trees), then reads large files to create pagecache pressure and
# evictable extent maps that trigger the shrinker.
#
# Usage: $0 <dev> <mnt>
# VM:    vng ... --cpus 8 --memory 1G --disk <img>
set -euo pipefail
DEV=${1:?Usage: $0 <dev> <mnt>}; MNT=${2:?}; NR=${NR:-200000}

# Inline C helper: create N empty files, hold fds open.
cat > /tmp/hold.c << 'EOF'
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
static volatile int run = 1;
static void h(int s) { (void)s; run = 0; }
int main(int argc, char **argv) {
	int n = atoi(argv[2]);
	struct rlimit rl = { n + 64, n + 64 };
	setrlimit(RLIMIT_NOFILE, &rl);
	int *fds = calloc(n, sizeof(int));
	char p[256];
	mkdir(argv[1], 0755);
	for (int i = 0; i < n; i++) {
		snprintf(p, sizeof(p), "%s/%d", argv[1], i);
		fds[i] = open(p, O_CREAT | O_RDONLY, 0644);
		if (fds[i] < 0) break;
		if (i % 50000 == 0) fprintf(stderr, "%d/%d\n", i, n);
	}
	fprintf(stderr, "holding %d files\n", n);
	signal(SIGTERM, h); signal(SIGINT, h);
	while (run) pause();
	for (int i = 0; i < n; i++) if (fds[i] >= 0) close(fds[i]);
	free(fds);
}
EOF
cc -O2 -o /tmp/hold /tmp/hold.c

trap 'kill 0 2>/dev/null; wait; umount "$MNT" 2>/dev/null' EXIT
mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT"
mkfs.btrfs -f "$DEV" >/dev/null
mount -o noatime "$DEV" "$MNT"

# 200k empty files — populates xarray with empty extent map trees.
/tmp/hold "$MNT/files" "$NR" &

# Large files read in parallel — total > RAM so pagecache constantly
# churns. The reads create evictable extent maps that trigger the
# EM shrinker via btrfs_free_cached_objects().
for i in 1 2 3 4; do
	dd if=/dev/zero of="$MNT/big.$i" bs=1M count=512 status=none
done
sync
for i in 1 2 3 4; do
	while true; do cat "$MNT/big.$i" > /dev/null; done &
done

echo "running — Ctrl-C to stop"
wait
