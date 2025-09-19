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

_setup() {
	[ -f .done ] && rm .done
	_umount_loop $dev
	_fresh_btrfs_mnt $dev $mnt "-o ssd_spread"
	#if [ -f .re-mkfs ]; then
		#_fresh_btrfs_mnt $dev $mnt
	#else
		#_btrfs_mnt $dev $mnt
	#fi
	rm .re-mkfs &>/dev/null
}

# write big, medium, small extent
one_iter() {
	local i=$1
	dd if=/dev/zero of=$mnt/big.$i bs=16M count=1 &>/dev/null
	dd if=/dev/zero of=$mnt/med.$i bs=4M count=1 &>/dev/null
	#dd if=/dev/zero of=$mnt/small.$i bs=64K count=1 &>/dev/null
	sync
	btrfs fi usage $mnt
}

_setup

for i in $(seq 3); do
	one_iter $i;
done
