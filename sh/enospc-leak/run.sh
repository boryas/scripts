#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

SZ=$(lsblk $dev -nb -o SIZE)
GiB=$((1<<30))

_setup() {
	$MKFS -f -m single -d single $dev >/dev/null 2>&1
	mount -o noatime,compress-force=zstd:3 $dev $mnt
	fallocate -l $((SZ-GiB)) $mnt/filler
	sync
}

_setup

# should enospc and thus leak
for i in $(seq 100); do
	dd if=/dev/urandom of=/mnt/lol/f.$i bs=100M count=1
	sync
done
