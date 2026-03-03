#!/bin/bash
# Minimal reproducer for btrfs orphan_cleanup -ENOENT race.
# Shell-only, no python. Requires: dm-delay, btrfs-progs, xfs_io, awk.
# Usage: ./repro.sh <dev> [attempts]
#   <dev> must be >=12GB, safe to format.

set -euo pipefail

DEV=${1:?usage: $0 <dev> [attempts]}
ATTEMPTS=${2:-20}
MNT=/mnt/root
DM=orphan-test-delay
DELAY_MS=2000
SIZE_MB=8192

cleanup() {
	cd /
	exec 3>&- 2>/dev/null ||:
	umount $MNT 2>/dev/null ||:
	dmsetup remove $DM 2>/dev/null ||:
}
trap cleanup EXIT

modprobe dm_delay 2>/dev/null ||:
dmsetup targets 2>/dev/null | grep -q '^delay' || { echo "FATAL: no dm-delay"; exit 1; }
mkdir -p $MNT

for i in $(seq 1 $ATTEMPTS); do
	sleep_val=$(awk "BEGIN{printf \"%.2f\", $DELAY_MS/1000 + ($i-1) * 1.0/$ATTEMPTS}")
	echo -n "  attempt $i (sleep=${sleep_val}s): "
	dmesg -C 2>/dev/null ||:
	cleanup

	# Fast setup: dm-delay with 0ms, mkfs, mount, create subvol + big file
	SEC=$(blockdev --getsz "$DEV")
	echo "0 $SEC delay $DEV 0 0 $DEV 0 0" | dmsetup create $DM
	mkfs.btrfs -f /dev/mapper/$DM >/dev/null 2>&1
	mount /dev/mapper/$DM $MNT
	btrfs subvolume create $MNT/sub >/dev/null
	dd if=/dev/zero of=$MNT/sub/big bs=1M count=$SIZE_MB status=none
	sync

	# Switch to delayed writes
	echo "0 $SEC delay $DEV 0 0 $DEV 0 $DELAY_MS" | dmsetup reload $DM
	dmsetup suspend $DM; dmsetup resume $DM

	# Shell fd trick to simulate open/write/unlink/close from a single
	# process without needing C or python:
	#
	#   exec 3<>file  - opens "file" on fd 3 of this shell process.
	#                   The kernel increments i_count (igrab), so the
	#                   inode stays alive even after unlink.
	#
	#   xfs_io /proc/self/fd/3
	#                 - xfs_io inherits fd 3; /proc/self/fd/3 lets it
	#                   open the same vnode (same struct file).  pwrite
	#                   dirties pages, sync_range submits writeback.
	#                   dm-delay holds the IO in-flight, so ordered
	#                   extents keep igrab refs on the inode.  When
	#                   xfs_io exits, its copy of the fd closes, but
	#                   the shell's fd 3 keeps the file open.
	#
	#   rm file       - unlinks the directory entry.  nlink drops to 0,
	#                   btrfs creates an orphan item.  The inode is NOT
	#                   evicted yet because fd 3 still holds a reference.
	#
	#   exec 3>&-     - closes fd 3 in the shell, dropping the last
	#                   reference.  iput() runs, but ordered extents are
	#                   still in-flight (dm-delay), so eviction is
	#                   deferred to the cleaner kthread via delayed_iput.
	#
	exec 3<>$MNT/sub/big
	xfs_io -c "pwrite -S 0x41 -b 1m 0 500m" \
	       -c "sync_range -w 0 500m" \
	       /proc/self/fd/3 >/dev/null
	rm $MNT/sub/big
	exec 3>&-

	# Evict subvolume dentry from dcache
	echo 2 > /proc/sys/vm/drop_caches

	# Probe: ls triggers btrfs_orphan_cleanup (ORPHAN_CLEANUP bit was
	# never set because create_subvol uses d_instantiate).
	# Must land while eviction is in progress (I_FREEING set).
	sleep "$sleep_val"
	ls $MNT/sub/ >/dev/null 2>&1 ||:

	if dmesg 2>/dev/null | grep -q "could not do orphan cleanup -2$"; then
		echo "HIT"
		echo ""
		echo "*** BUG REPRODUCED (attempt $i, sleep=${sleep_val}s) ***"
		dmesg | grep "could not do orphan cleanup -2$" | tail -1
		stat $MNT/sub >/dev/null 2>&1 || echo "CONFIRMED: negative dentry"
		exit 0
	fi
	echo "miss"
done

echo ""; echo "Not reproduced in $ATTEMPTS attempts. Try: $0 $DEV 40"
exit 1
