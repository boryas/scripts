#!/usr/bin/env bash
# Parallel stress test for reclaim + relocation refcount bug
# Bug: Block group refcount leak when dynamic/periodic reclaim triggers
#      relocation that hits ENOSPC during cache truncation

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 4 ]; then
	_err "usage: $SCRIPT <dev> <mnt> <duration_seconds> <num_workers>"
	_usage
fi

dev=$1
mnt=$2
duration=${3:-60}
num_workers=${4:-4}

# Worker: Writes and deletes files to create block group churn
worker_file_churn() {
	local worker_id=$1
	local flag_file=/tmp/btrfs-worker-${worker_id}.run
	touch $flag_file

	local counter=0
	while [ -f $flag_file ]; do
		local worker_dir=$mnt/worker_${worker_id}
		mkdir -p $worker_dir 2>/dev/null || true

		# Write files
		for i in $(seq 1 10); do
			dd if=/dev/urandom of=$worker_dir/file_${counter}_${i} \
				bs=1M count=$((RANDOM % 50 + 10)) 2>/dev/null || true
		done

		# Sync to force allocation
		sync

		# Delete some files to create fragmentation
		for i in $(seq 1 2 10); do
			rm $worker_dir/file_${counter}_${i} 2>/dev/null || true
		done

		# Occasionally sync to trigger reclaim
		if [ $((counter % 5)) -eq 0 ]; then
			$BTRFS filesystem sync $mnt 2>/dev/null || true
		fi

		counter=$((counter + 1))
		sleep 0.$((RANDOM % 5))  # Random delay
	done

	_log "[Worker $worker_id] Stopped after $counter iterations"
}

# Worker: Forces balance operations
worker_balance() {
	local worker_id=$1
	local flag_file=/tmp/btrfs-balance-${worker_id}.run
	touch $flag_file

	local counter=0
	while [ -f $flag_file ]; do
		# Try to start a balance on a small usage range
		# This will compete with reclaim for block groups
		$BTRFS balance start -dusage=5 $mnt 2>/dev/null || true

		sleep $((2 + RANDOM % 3))

		# Cancel the balance
		$BTRFS balance cancel $mnt 2>/dev/null || true

		counter=$((counter + 1))
		sleep $((1 + RANDOM % 2))
	done

	_log "[Balance Worker $worker_id] Stopped after $counter iterations"
}

# Cleanup function
cleanup() {
	_log "Stopping workers..."
	rm -f /tmp/btrfs-worker-*.run 2>/dev/null || true
	rm -f /tmp/btrfs-balance-*.run 2>/dev/null || true
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Setup
_umount_loop $dev
_fresh_btrfs_mnt $dev $mnt

# Enable dynamic and periodic reclaim
_log "Enabling dynamic and periodic reclaim"
sysfs=$(_btrfs_sysfs $dev)
echo 1 > $sysfs/allocation/data/dynamic_reclaim
echo 1 > $sysfs/allocation/data/periodic_reclaim

# Pre-fill filesystem to ~80% to make reclaim more likely
_log "Pre-filling filesystem to trigger reclaim conditions"
fill_dir=$mnt/initial_fill
mkdir -p $fill_dir

total_size=$(df -B1 $mnt | tail -1 | awk '{print $2}')
target_size=$((total_size * 80 / 100))
files_needed=$((target_size / (100 * 1024 * 1024)))

_log "Creating ${files_needed} initial files"
for i in $(seq 1 $files_needed); do
	dd if=/dev/urandom of=$fill_dir/file_$i bs=1M count=100 2>/dev/null
	if [ $((i % 10)) -eq 0 ]; then
		_log "  Initial fill: $i / $files_needed files..."
	fi
done

sync
$BTRFS filesystem sync $mnt

# Delete some to create space
_log "Deleting 30% of files to create reclaim opportunities"
for i in $(seq 3 3 $files_needed); do
	rm $fill_dir/file_$i 2>/dev/null || true
done

sync
$BTRFS filesystem sync $mnt
sleep 2

# Launch file churn workers
_log "Launching $num_workers file churn workers for ${duration}s"
for i in $(seq $num_workers); do
	worker_file_churn $i &
done

# Launch balance worker (just one)
_log "Launching balance worker"
worker_balance 1 &

# Run for duration
_log "Running stress test for ${duration} seconds..."
sleep $duration

# Stop workers
_log "Stopping workers..."
rm -f /tmp/btrfs-worker-*.run
rm -f /tmp/btrfs-balance-*.run
wait

# Give reclaim time to settle
_log "Waiting for reclaim to settle..."
sleep 5
$BTRFS filesystem sync $mnt
sleep 5

# Check dmesg for the bug
_log "Checking dmesg for refcount issues..."
echo ""
_happy "=== Relevant dmesg output (last 100 lines with 'BO:' or 'btrfs') ==="
dmesg | grep -E 'BO:|btrfs' | tail -100 || true
echo ""

_log "Parallel test complete. Check dmesg output above for:"
_log "  1. 'BO: <pid> inject enospc' - ENOSPC injection triggered"
_log "  2. Multiple 'BO: <pid> reloc put bg' - Relocation putting block groups"
_log "  3. Multiple 'BO: <pid> reclaim loop put bg' - Reclaim putting block groups"
echo ""
_log "Look for interleaved reloc/reclaim operations on the same block group"

# Cleanup
_umount_loop $dev
_happy "Parallel test done!"
