#!/usr/bin/env bash
# Standalone minimal reproducer for reclaim + relocation refcount bug
# Bug: Block group refcount leak when dynamic/periodic reclaim triggers
#      relocation that hits ENOSPC during cache truncation

set -e

if [ $# -ne 2 ]; then
	echo "usage: $0 <dev> <mnt>"
	exit 1
fi

dev=$1
mnt=$2

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

log() {
	echo -e "${BLUE}$@${PLAIN}"
}

err() {
	echo -e "${RED}$@${PLAIN}"
}

happy() {
	echo -e "${GREEN}$@${PLAIN}"
}

# Cleanup
for i in $(seq 100); do
	findmnt $dev >/dev/null || break
	umount $dev 2>/dev/null || true
done

# Create filesystem
log "Creating fresh btrfs filesystem"
mkfs.btrfs -f -m dup -d single $dev >/dev/null || exit 1
mount -o noatime $dev $mnt || exit 1

# Enable dynamic and periodic reclaim
uuid=$(btrfs fi show $dev | grep uuid: | awk '{print $4}')
sysfs_path="/sys/fs/btrfs/$uuid/allocation/data"

log "Enabling dynamic and periodic reclaim"
echo 1 > $sysfs_path/dynamic_reclaim
echo 1 > $sysfs_path/periodic_reclaim

# Fill up the filesystem to trigger reclaim
# We want to create enough data to have multiple block groups
# that will be candidates for reclaim
log "Filling filesystem to trigger reclaim (this may take a minute...)"
fill_dir=$mnt/fill_data
mkdir -p $fill_dir

# Create ~95% full to ensure reclaim will be triggered
# Use fallocate for speed, then overwrite some with real data
total_size=$(df -B1 $mnt | tail -1 | awk '{print $2}')
target_size=$((total_size * 95 / 100))
files_needed=$((target_size / (100 * 1024 * 1024)))  # 100MB files

log "Creating ${files_needed} files of 100MB each"
for i in $(seq 1 $files_needed); do
	dd if=/dev/urandom of=$fill_dir/file_$i bs=1M count=100 2>/dev/null
	# Sync every 10 files to spread across block groups
	if [ $((i % 10)) -eq 0 ]; then
		sync
		log "  Created $i / $files_needed files..."
	fi
done

sync
log "Initial fill complete, syncing filesystem"
btrfs filesystem sync $mnt

# Now delete some files to create fragmentation and trigger reclaim
log "Creating fragmentation by deleting half the files"
for i in $(seq 2 2 $files_needed); do
	rm $fill_dir/file_$i 2>/dev/null || true
done

sync
btrfs filesystem sync $mnt
sleep 2

# Force reclaim to start by writing more data
log "Writing more data to trigger reclaim"
for i in $(seq 1 50); do
	dd if=/dev/urandom of=$fill_dir/new_file_$i bs=1M count=50 2>/dev/null || true
done

sync
btrfs filesystem sync $mnt
sleep 3

# Trigger the reclaim worker explicitly
log "Waiting for reclaim to process (check dmesg for debug output)..."
sleep 5
btrfs filesystem sync $mnt
sleep 5

# Check dmesg for the bug
log "Checking dmesg for refcount issues..."
echo ""
happy "=== Relevant dmesg output (last 50 lines with 'BO:' or 'btrfs') ==="
dmesg | grep -E 'BO:|btrfs' | tail -50 || true
echo ""

log "Test complete. Check dmesg output above for:"
log "  1. 'BO: <pid> inject enospc' - ENOSPC injection triggered"
log "  2. 'BO: <pid> reloc put bg' - Relocation putting block group"
log "  3. 'BO: <pid> reclaim loop put bg' - Reclaim loop putting block group"
log ""
log "If both relocation and reclaim are putting the same bg, there may be a refcount leak"

# Cleanup
log "Cleaning up"
umount $mnt
happy "Done!"
