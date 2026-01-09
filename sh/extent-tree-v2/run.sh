#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

_umount_loop $dev

/work/src/btrfs-progs/mkfs.btrfs -f -O extent-tree-v2 $dev
mount $dev $mnt

for i in $(seq 27)
do
	dd if=/dev/zero of=$mnt/foo.$i bs=4M count=10
	sync
done
