#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
f=$mnt/f
NR_EXTENTS=8
EXTENT_SZ=128M

# race reclaim against async discard
_fresh_btrfs_mnt $dev $mnt -o discard=async

_kmsg "write $NR_EXTENTS $EXTENT_SZ extents"
for i in $(seq $NR_EXTENTS)
do
	dd if=/dev/zero of=$f.$i bs=$EXTENT_SZ count=1
done

sync

_kmsg "sleep 27"
sleep 27

echo 30 > $(_btrfs_sysfs_space_info $dev data)/bg_reclaim_threshold
_kmsg "erase $(($NR_EXTENTS - 2)) extents"
for i in $(seq 3 $NR_EXTENTS | sort -nr)
do
	rm $f.$i
done
sync

# create a new txn so kthread runs
touch bar

sleep 3
_kmsg "expect reclaim to start" # this sleeps 5 after checking unpinning

sleep 1
_kmsg "erase last 2 extents"
for i in $(seq 2 | sort -nr)
do
	rm $f.$i
done
sync & # sleeps X before queuing discard

sleep 2
_kmsg "expect reclaim to run on the bg"

sleep 3
_kmsg "expect unpin"

sleep 10
_kmsg "expect reclaim to delete the block group" # 16 after start reclaim
_kmsg "expect discard to run on the block group" # 10 after unpin

_ok
