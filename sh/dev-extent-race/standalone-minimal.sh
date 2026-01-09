#!/usr/bin/env bash
# Standalone minimal reproducer for dev extent race bug
# Bug: EEXIST when inserting dev extent during block group creation
#
# Error: BTRFS: error (device nvme0n1p2 state A) in
#        btrfs_create_pending_block_groups:2772: errno=-17 Object already exists
#
# Race between:
#   - Balance relocating block groups (frees dev extents)
#   - force_chunk_alloc creating new block groups (inserts dev extents)

set -e

if [ $# -ne 2 ]; then
	echo "usage: $0 <dev> <mnt>"
	exit 1
fi

dev=$1
mnt=$2
duration=${3:-60}

# Get btrfs UUID for sysfs path
get_uuid() {
	btrfs filesystem show "$1" | grep uuid: | awk '{print $4}'
}

# Check for the bug in dmesg
check_for_bug() {
	dmesg | grep -q "errno=-17 Object already exists"
}

# Cleanup function
cleanup() {
	echo "Stopping workers..."
	rm -f /tmp/btrfs-force-alloc.run 2>/dev/null || true
	rm -f /tmp/btrfs-balance.run 2>/dev/null || true
	rm -f /tmp/btrfs-file-io.run 2>/dev/null || true
	wait 2>/dev/null || true
	umount "$mnt" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Setup filesystem
echo "Setting up filesystem on $dev..."
umount "$dev" 2>/dev/null || true
mkfs.btrfs -f "$dev" >/dev/null
mount "$dev" "$mnt"

uuid=$(get_uuid "$dev")
sysfs="/sys/fs/btrfs/$uuid"

# Pre-fill filesystem
echo "Pre-filling filesystem..."
for i in $(seq 1 20); do
	dd if=/dev/urandom of="$mnt/initial_$i" bs=1M count=10 2>/dev/null
done
sync

# Worker: Force chunk allocation with delay
worker_force_alloc() {
	touch /tmp/btrfs-force-alloc.run
	while [ -f /tmp/btrfs-force-alloc.run ]; do
		echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null || true
		echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null || true
		sleep 1
	done
}

# Worker: Continuous balance
worker_balance() {
	touch /tmp/btrfs-balance.run
	while [ -f /tmp/btrfs-balance.run ]; do
		btrfs balance start -dusage=100 "$mnt" 2>/dev/null || true
		sleep 0.1
	done
}

# Worker: File I/O
worker_file_io() {
	touch /tmp/btrfs-file-io.run
	local counter=0
	while [ -f /tmp/btrfs-file-io.run ]; do
		dd if=/dev/urandom of="$mnt/file_$((counter % 10))" bs=1M count=10 2>/dev/null || true
		((counter++))
		sleep 0.5
	done
}

echo "Starting workers for ${duration}s..."
worker_force_alloc &
worker_balance &
worker_file_io &

# Run for duration, checking for bug
elapsed=0
while [ $elapsed -lt $duration ]; do
	sleep 5
	elapsed=$((elapsed + 5))
	if check_for_bug; then
		echo "BUG REPRODUCED after ${elapsed}s!"
		dmesg | grep -E "errno=-17|Object already exists" | tail -5
		exit 0
	fi
	echo "Running... ${elapsed}s / ${duration}s"
done

echo "Bug not reproduced in ${duration}s"
