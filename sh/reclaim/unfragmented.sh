#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
f=$mnt/f

_fresh_btrfs_mnt $dev $mnt

for i in $(seq 16)
do
	dd if=/dev/zero of=$f.$i bs=128M count=1
done

_cycle_mnt $dev $mnt
echo 25 > $(_btrfs_sysfs_space_info $dev data)/bg_reclaim_threshold

for i in $(seq 9 16 | sort -nr)
do
	rm $f.$i
	sync
done

$BTRFS filesystem usage $mnt
