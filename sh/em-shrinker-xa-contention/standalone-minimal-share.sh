#!/usr/bin/env bash
# Reproducer: btrfs EM shrinker xa_lock contention (PREEMPT_NONE).
#
# find_first_inode_to_shrink() holds root->inodes.xa_lock for an entire
# scheduler timeslice (~2.8ms on 8 CPUs) while iterating inodes, because
# cond_resched_lock() + spin_needbreak()=0 only drops at tick boundaries.
#
# kswapd's super_cache_scan() calls both prune_icache_sb() (which evicts
# inodes via btrfs_del_inode_from_root → xa_lock) and free_cached_objects()
# (which triggers the EM shrinker → find_first_inode_to_shrink → xa_lock).
# Both paths contend on the same lock on the same root.
#
# Usage: $0 <dev> <mnt>
# VM:    vng ... --cpus 8 --memory 1G --disk <img>
set -euo pipefail
DEV=${1:?Usage: $0 <dev> <mnt>}; MNT=${2:?}; NR=${NR:-500000}

trap 'kill 0 2>/dev/null; wait; umount "$MNT" 2>/dev/null' EXIT
mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT"
mkfs.btrfs -f "$DEV" >/dev/null
mount -o noatime "$DEV" "$MNT"

# Create many files — populates the xarray. No fds held, so all inodes
# are reclaimable (i_count=0). kswapd evicts them via prune_icache_sb →
# btrfs_del_inode_from_root → xa_lock.
echo "creating $NR files..."
mkdir -p "$MNT/files"
(cd "$MNT/files" && seq 0 $((NR - 1)) | xargs -n 2000 touch)
echo "done"

# Large files read in parallel — total > RAM for sustained pressure.
# Reads create evictable extent maps (evictable_extent_maps > 0) so the
# VFS calls free_cached_objects → EM shrinker → find_first_inode_to_shrink
# which holds xa_lock while iterating through all the inodes above.
for i in 1 2 3 4; do
	dd if=/dev/zero of="$MNT/big.$i" bs=1M count=512 status=none
done
sync

echo "starting pressure — observe contention window now"
for i in 1 2 3 4; do
	while true; do cat "$MNT/big.$i" > /dev/null; done &
done
wait
