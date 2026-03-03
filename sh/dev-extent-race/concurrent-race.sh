#!/usr/bin/env bash
# Reproducer for dev extent race bug - concurrent version
#
# Strategy: Run balance/cleaner in background while forcing allocations
# to try to catch a race where:
# 1. Cleaner removes a chunk (clears CHUNK_ALLOCATED, doesn't commit yet)
# 2. We force allocate (sees old commit root, but CHUNK_ALLOCATED has gap)
# 3. Another allocation might overlap

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 2 ]; then
	echo "Usage: $0 <dev> <mnt> [iterations]"
	exit 1
fi

dev=$1
mnt=$2
iterations=${3:-10}

_log "=== Concurrent Allocation Race Reproducer ==="
_log "Device: $dev"
_log "Mount: $mnt"
_log "Iterations: $iterations"

for iter in $(seq 1 $iterations); do
	_log ""
	_log "=== Iteration $iter/$iterations ==="

	# Setup fresh filesystem
	_umount_loop "$dev"
	_fresh_btrfs_mnt "$dev" "$mnt"
	sysfs=$(_btrfs_sysfs "$dev")

	# Create files to fill some chunks
	_log "Creating data files..."
	for i in $(seq 1 8); do
		dd if=/dev/urandom of="$mnt/file_$i" bs=1M count=256 2>/dev/null &
	done
	wait
	sync

	# Delete alternating files to create empty chunks
	_log "Deleting alternating files..."
	for i in 2 4 6 8; do
		rm "$mnt/file_$i"
	done
	sync

	# Start balance in background (will try to remove empty chunks)
	_log "Starting balance in background..."
	btrfs balance start -dusage=5 "$mnt" &>/dev/null &
	balance_pid=$!

	# While balance is running, force allocations rapidly
	_log "Forcing allocations while balance runs..."
	for j in $(seq 1 5); do
		echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null &
		echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null &
	done

	# Wait a bit then cancel balance
	sleep 1
	btrfs balance cancel "$mnt" 2>/dev/null || true
	wait $balance_pid 2>/dev/null || true

	# Check for errors immediately
	if dmesg | tail -50 | grep -q "errno=-17\|EEXIST"; then
		_sad "FOUND EEXIST ERROR in iteration $iter!"
		dmesg | grep -E "errno=-17|EEXIST" | tail -5

		_log "Current chunk state:"
		if command -v drgn &>/dev/null; then
			drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null || true
		fi
		break
	fi
done

if ! dmesg | tail -200 | grep -q "errno=-17\|EEXIST"; then
	_log "No EEXIST errors found after $iterations iterations"
fi

_log ""
_log "=== Done ==="
