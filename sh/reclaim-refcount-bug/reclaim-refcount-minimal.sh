#!/usr/bin/env bash
# Minimal reproducer for reclaim + relocation refcount bug
# Bug: Block group refcount leak when dynamic/periodic reclaim triggers
#      relocation that hits ENOSPC during cache truncation

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2

# Cleanup and create fresh filesystem
_umount_loop $dev
_fresh_btrfs_mnt $dev $mnt

# Enable dynamic and periodic reclaim
_log "Enabling dynamic and periodic reclaim"
sysfs=$(_btrfs_sysfs $dev)
echo 1 > $sysfs/allocation/data/dynamic_reclaim
echo 1 > $sysfs/allocation/data/periodic_reclaim

# Fill up the filesystem to trigger reclaim
_log "Filling filesystem to trigger reclaim (this may take a minute...)"
fill_dir=$mnt/fill_data
mkdir -p $fill_dir

# Create ~95% full to ensure reclaim will be triggered
total_size=$(df -B1 $mnt | tail -1 | awk '{print $2}')
target_size=$((total_size * 95 / 100))
files_needed=$((target_size / (100 * 1024 * 1024)))  # 100MB files

_log "Creating ${files_needed} files of 100MB each"
for i in $(seq 1 $files_needed); do
	dd if=/dev/urandom of=$fill_dir/file_$i bs=1M count=100 2>/dev/null
	# Sync every 10 files to spread across block groups
	if [ $((i % 10)) -eq 0 ]; then
		sync
		_log "  Created $i / $files_needed files..."
	fi
done

sync
$BTRFS filesystem sync $mnt

# Create fragmentation by deleting half the files
_log "Creating fragmentation by deleting half the files"
for i in $(seq 2 2 $files_needed); do
	rm $fill_dir/file_$i 2>/dev/null || true
done

sync
$BTRFS filesystem sync $mnt
sleep 2

# Force reclaim to start by writing more data
_log "Writing more data to trigger reclaim"
for i in $(seq 1 50); do
	dd if=/dev/urandom of=$fill_dir/new_file_$i bs=1M count=50 2>/dev/null || true
done

sync
$BTRFS filesystem sync $mnt
sleep 3

# Trigger the reclaim worker explicitly
_log "Waiting for reclaim to process (check dmesg for debug output)..."
$BTRFS filesystem sync $mnt
sleep 1
$BTRFS filesystem sync $mnt

# Check dmesg for the bug
_log "Checking dmesg for refcount issues..."
echo ""
_happy "=== Relevant dmesg output (last 50 lines with 'BO:' or 'btrfs') ==="
dmesg | grep -E 'BO:|btrfs' | tail -50 || true
echo ""

_log "Test complete. Check dmesg output above for:"
_log "  1. 'BO: <pid> inject enospc' - ENOSPC injection triggered"
_log "  2. 'BO: <pid> reloc put bg' - Relocation putting block group"
_log "  3. 'BO: <pid> reclaim loop put bg' - Reclaim loop putting block group"
echo ""
_log "If both relocation and reclaim are putting the same bg, there may be a refcount leak"

# Cleanup
_umount_loop $dev
_happy "Done!"
