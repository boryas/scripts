#!/usr/bin/env bash
#
# Reproducer for spinlock contention on btrfs root->inodes.xa_lock.
#
# Three threads contend on xa_lock:
#   1. Extent map shrinker (kworker): holds xa_lock while iterating inodes
#      in find_first_inode_to_shrink(). On PREEMPT_NONE, cond_resched_lock()
#      only drops at tick boundaries (~4ms). When many inodes have their
#      extent_tree.lock held (by I/O), write_trylock() fails and the
#      shrinker skips to the next inode — still holding xa_lock.
#   2. kswapd: evicting inodes via btrfs_del_inode_from_root() needs xa_lock.
#   3. Userspace: creating/unlinking files via btrfs_add_inode_to_root()
#      / btrfs_del_inode_from_root() needs xa_lock.
#
# Strategy:
#   - Create many files (100k) on one subvolume with 4K data each.
#   - Hold them all open and scatter-read them (hold extent_tree.lock
#     on many inodes so the shrinker's write_trylock fails repeatedly).
#   - Fast C-based create/unlink churn hammering xa_lock.
#   - Large-file reads drive pagecache pressure → kswapd → EM shrinker.
#
# Usage: standalone-minimal.sh <dev> <mnt> [duration_sec]
# VM:    vng --disable-microvm --user root --cpus 4 --memory 1G --disk ...

set -euo pipefail

dev=${1:?Usage: $0 <dev> <mnt> [duration_sec]}
mnt=${2:?Usage: $0 <dev> <mnt> [duration_sec]}
DURATION=${3:-60}

NR_PERSIST_FILES=${NR_PERSIST_FILES:-200000}
NR_CHURN_WORKERS=${NR_CHURN_WORKERS:-8}
NR_PRESSURE_READERS=${NR_PRESSURE_READERS:-4}
PRESSURE_FILE_SZ=${PRESSURE_FILE_SZ:-$((512 << 20))}
# What % of persist files to hold open; rest go to LRU for kswapd.
HOLD_PCT=${HOLD_PCT:-70}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cleanup() {
	echo "cleanup..."
	[ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null || true
	[ -n "${CHURN_PID:-}" ] && kill "$CHURN_PID" 2>/dev/null || true
	jobs -p | xargs -r kill 2>/dev/null || true
	wait 2>/dev/null
	sync 2>/dev/null
	sleep 1
	mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

echo -1000 > /proc/$$/oom_score_adj

# Build helpers
cc -O2 -pthread -o /tmp/hold-inodes "$SCRIPT_DIR/hold-inodes.c"
cc -O2 -pthread -o /tmp/churn "$SCRIPT_DIR/churn.c"
echo "Built helpers"

mountpoint -q "$mnt" && umount "$mnt"
mkfs.btrfs -f -m single -d single "$dev" >/dev/null
mount -o noatime "$dev" "$mnt"

# --- Phase 1: create files, hold open, scatter-read ---
echo "Phase 1: creating and holding $NR_PERSIST_FILES files..."
persist_dir="$mnt/persist"
/tmp/hold-inodes "$persist_dir" "$NR_PERSIST_FILES" 0 "$HOLD_PCT" 2>&1 &
HOLDER_PID=$!

echo "  waiting for hold-inodes (PID=$HOLDER_PID)..."
prev_inodes=0
stable=0
while true; do
	sleep 2
	kill -0 "$HOLDER_PID" 2>/dev/null || { echo "holder died"; exit 1; }
	cur=$(awk '{print $1}' /proc/sys/fs/inode-state 2>/dev/null)
	echo "  inodes: $cur"
	if [ "$cur" = "$prev_inodes" ] 2>/dev/null; then
		stable=$((stable + 1))
		[ "$stable" -ge 2 ] && break
	else
		stable=0
	fi
	prev_inodes=$cur
done
echo "  inode-state: $(cat /proc/sys/fs/inode-state 2>/dev/null)"

# --- Create files for pagecache memory pressure ---
echo "Creating pressure files..."
pressure_dir="$mnt/pressure"
mkdir -p "$pressure_dir"
for i in $(seq "$NR_PRESSURE_READERS"); do
	dd if=/dev/zero of="$pressure_dir/big.$i" bs=1M \
		count=$((PRESSURE_FILE_SZ >> 20)) status=none
done
sync
echo "Pressure files created (${NR_PRESSURE_READERS} x $((PRESSURE_FILE_SZ >> 20))MB)"

# --- Phase 2: start churn + pressure ---
echo ""
echo "Phase 2: starting workloads for ${DURATION}s"
echo "  $NR_CHURN_WORKERS churn threads (C create/unlink loop)"
echo "  $NR_PRESSURE_READERS pressure readers (pagecache churn)"

# C-based fast churn
/tmp/churn "$mnt/churn" "$NR_CHURN_WORKERS" "$DURATION" 2>&1 &
CHURN_PID=$!

# Shell-based pressure readers
for i in $(seq "$NR_PRESSURE_READERS"); do
	(while [ -e /proc/$CHURN_PID ]; do
		cat "$pressure_dir/big.$i" > /dev/null 2>&1 || true
	done) &
done

echo "=== vmstat before ==="
grep -E 'pgscan_direct|pgsteal_direct|pgscan_kswapd|pgsteal_kswapd' /proc/vmstat

# Monitor
(
prev_scan_k=0; prev_scan_d=0
while [ -e /proc/$CHURN_PID ] 2>/dev/null; do
	scan_k=$(awk '/pgscan_kswapd / {print $2}' /proc/vmstat)
	scan_d=$(awk '/pgscan_direct / {print $2}' /proc/vmstat)
	dk=$((scan_k - prev_scan_k)); dd=$((scan_d - prev_scan_d))
	free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
	istate=$(cat /proc/sys/fs/inode-state 2>/dev/null)
	echo "POLL: free=${free}MB scan_k=+$dk scan_d=+$dd inode-state=$istate"
	prev_scan_k=$scan_k; prev_scan_d=$scan_d
	sleep 5
done
) &

wait "$CHURN_PID" 2>/dev/null || true
CHURN_PID=
echo "stopping..."
kill "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=
jobs -p | xargs -r kill 2>/dev/null || true
wait 2>/dev/null || true

echo ""
echo "=== vmstat after ==="
grep -E 'pgscan_direct|pgsteal_direct|pgscan_kswapd|pgsteal_kswapd' /proc/vmstat
echo "=== memory pressure ==="
cat /proc/pressure/memory
echo "=== CPU pressure ==="
cat /proc/pressure/cpu 2>/dev/null || true
echo "done"
