#!/usr/bin/env bash
# Parallel stress test for dev extent race bug
# Bug: EEXIST when inserting dev extent during block group creation
#      Race between balance (removing old block groups) and force_chunk_alloc
#      (creating new block groups at same physical offset)

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 3 ]; then
	_err "usage: $SCRIPT <dev> <mnt> <duration_seconds>"
	_usage
fi

dev=$1
mnt=$2
duration=${3:-60}

# Worker: Force chunk allocation with delay to avoid ENOSPC
worker_metadata_force_alloc() {
	local sysfs=$1
	local flag_file="/tmp/btrfs-force-alloc.run"
	touch "$flag_file"

	local counter=0
	while [ -f "$flag_file" ]; do
		echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null || true
		((counter++))
		# Short delay to increase contention while avoiding ENOSPC
		#sleep 0.1
	done

	_log "[Force Alloc Worker] Stopped after $counter iterations"
}

worker_data_force_alloc() {
	local sysfs=$1
	local flag_file="/tmp/btrfs-force-alloc.run"
	touch "$flag_file"

	local counter=0
	while [ -f "$flag_file" ]; do
		echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null || true
		((counter++))
		# Short delay to increase contention while avoiding ENOSPC
		#sleep 0.1
	done

	_log "[Force Alloc Worker] Stopped after $counter iterations"
}

# Worker: Continuous balance to relocate/delete block groups
worker_balance() {
	local mnt=$1
	local flag_file="/tmp/btrfs-balance.run"
	touch "$flag_file"

	local counter=0
	while [ -f "$flag_file" ]; do
		# Balance all data block groups - relocates them, freeing old dev extents
		$BTRFS balance start -musage=100 -dusage=100 "$mnt" 2>/dev/null || true
		((counter++))
		# Small delay before next iteration
		sleep 0.1
	done

	_log "[Balance Worker] Stopped after $counter iterations"
}

# Worker: File I/O to keep block groups populated
worker_file_io() {
	local mnt=$1
	local flag_file="/tmp/btrfs-file-io.run"
	touch "$flag_file"

	local counter=0
	while [ -f "$flag_file" ]; do
		# Create some data to keep block groups populated
		dd if=/dev/urandom of="$mnt/file_$((counter % 10))" bs=1M count=10 2>/dev/null || true
		((counter++))
		sleep 0.5
	done

	_log "[File I/O Worker] Stopped after $counter iterations"
}

# Check for the bug in dmesg
check_for_bug() {
	if dmesg | grep -q "errno=-17 Object already exists"; then
		return 0  # Bug found
	fi
	return 1
}

# Cleanup function
cleanup() {
	_log "Stopping workers..."
	rm -f /tmp/btrfs-force-alloc.run 2>/dev/null || true
	rm -f /tmp/btrfs-balance.run 2>/dev/null || true
	rm -f /tmp/btrfs-file-io.run 2>/dev/null || true
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Setup
_log "Setting up filesystem..."
_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"

sysfs=$(_btrfs_sysfs "$dev")

# Pre-fill filesystem with some data
_log "Pre-filling filesystem with initial data..."
for i in $(seq 1 20); do
	dd if=/dev/urandom of="$mnt/initial_$i" bs=1M count=10 2>/dev/null
done
sync

_log "Starting workers for ${duration} seconds..."
_log "  - Force chunk alloc worker (1s delay)"
_log "  - Balance worker (usage=100)"
_log "  - File I/O worker"

# Launch workers
worker_data_force_alloc "$sysfs" &
worker_metadata_force_alloc "$sysfs" &
#worker_balance "$mnt" &
#worker_file_io "$mnt" &

# Run for duration, checking for bug periodically
bug_found=0
elapsed=0
check_interval=5

while [ $elapsed -lt $duration ]; do
	sleep $check_interval
	elapsed=$((elapsed + check_interval))

	if check_for_bug; then
		_sad "BUG REPRODUCED after ${elapsed}s!"
		bug_found=1
		break
	fi

	_log "Running... ${elapsed}s / ${duration}s"
done

# Stop workers
_log "Stopping workers..."
rm -f /tmp/btrfs-force-alloc.run
rm -f /tmp/btrfs-balance.run
rm -f /tmp/btrfs-file-io.run
wait

# Final check
_log "Checking dmesg for bug..."
echo ""

if check_for_bug || [ $bug_found -eq 1 ]; then
	_sad "=== BUG REPRODUCED ==="
	dmesg | grep -E "errno=-17|Object already exists|btrfs_create_pending_block_groups" | tail -20
	echo ""
	_sad "Bug found: EEXIST in btrfs_create_pending_block_groups"
	_umount_loop "$dev"
	exit 0
else
	_happy "Bug not reproduced in this run"
	_log "Relevant dmesg (last 20 btrfs lines):"
	dmesg | grep -i btrfs | tail -20 || true
fi

# Cleanup
_umount_loop "$dev"
_happy "Test complete"
