#!/usr/bin/env bash
# Parallel stress test for dev extent race bug
# Bug: EEXIST when inserting dev extent during block group creation
#      Race between balance (removing old block groups) and force_chunk_alloc
#      (creating new block groups at same physical offset)

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS=$(dirname "$SH_ROOT")
DRGN=$SCRIPTS/drgn
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 2 ]; then
	_err "usage: $SCRIPT <dev> <mnt>"
	_usage
fi

dev=$1
mnt=$2


_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"

# cleaner thread to hit delete_unused_bgs
_cleaner() {
	btrfs fi sync $mnt
	sleep 1
	btrfs fi sync $mnt
}

_cleaner &

sleep 1

for i in $(seq 0 15); do
	dd if=/dev/zero of=$mnt/foo.$i bs=1M count=256
done

# 9-15 covers >1G so a bg will be freed
for i in $(seq 9 15); do
	rm $mnt/foo.$i
done


$DRGN/dump_chunk_allocated.py $mnt
#$DRGN/dump_commit_root_dev_extents.py $mnt

# kernel should be stuck in deleting commit and show the gap
echo 1 > "$(_btrfs_sysfs_space_info $dev metadata)/force_chunk_alloc"
