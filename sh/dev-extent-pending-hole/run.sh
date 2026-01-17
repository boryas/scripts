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
	_log "fire cleaner thread"
	btrfs fi sync $mnt
	sleep 1
	btrfs fi sync $mnt
}

_log "push the BG frontier"
fallocate -l 20G $mnt/foo
_log "one more"
fallocate -l 1G $mnt/sticky
_log "sync"
sync
_log "rm big gap of bgs"
rm $mnt/foo
_log "sync"
sync
_cleaner
_log "let everything quiesce"
sleep 20
_log "sync"
sync

# should have one bg 20G out and the rest at the beginning..
# sort of like an empty FS but with a random sticky chunk

_cleaner &

_log "sleep 3 after cleaner thread"
sleep 3

_log "force alloc meta"
echo 1 > "$(_btrfs_sysfs_space_info $dev metadata)/force_chunk_alloc"
_log "force alloc data"
echo 1 > "$(_btrfs_sysfs_space_info $dev data)/force_chunk_alloc"
_log "force alloc meta"
echo 1 > "$(_btrfs_sysfs_space_info $dev metadata)/force_chunk_alloc"
_log "force alloc data"
echo 1 > "$(_btrfs_sysfs_space_info $dev data)/force_chunk_alloc"

_log "sleep 10"
sleep 10

_log "force alloc meta"
echo 1 > "$(_btrfs_sysfs_space_info $dev metadata)/force_chunk_alloc"

$DRGN/dump_chunk_maps.py $mnt
#$DRGN/dump_chunk_allocated.py $mnt
#$DRGN/dump_commit_root_dev_extents.py $mnt
