#!/usr/bin/env bash
SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")

source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2

_umount_loop $dev

/mnt/repos/btrfs-progs/mkfs.btrfs -f $dev -O extent-tree-v2
mount $dev $mnt

for i in $(seq 10); do
	dd if=/dev/zero of=$mnt/foo.$i bs=4M count=10
	sync
done
