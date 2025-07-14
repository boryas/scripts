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

_create_fs() {
	_log "create new dynrec test fs."
	sudo fallocate -l 108G $mnt/giganto
}

_setup() {
	[ -f .done ] && rm .done
	if [ -f .re-mkfs ]; then
		_umount_loop $dev
		_fresh_btrfs_mnt $dev $mnt "-o" "compress-force=zstd:3"
	else
		_btrfs_mnt $dev $mnt "-o" "compress-force=zstd:3"
		if [ ! -f $mnt/cmpr ]; then
			_umount_loop $dev
			_fresh_btrfs_mnt $dev $mnt "-o" "compress-force=zstd:3"
		fi
	fi
	[ -f .re-mkfs ] && _create_fs
	[ -f $mnt/giganto ] || _create_fs
	rm .re-mkfs &>/dev/null

	local sysfs=$(_btrfs_sysfs $dev)
	local si=$sysfs/allocation/data
	echo 1 > $si/dynamic_reclaim
	echo 1 > $si/periodic_reclaim
}

_setup

btrfs subvol create $mnt/sv
for i in $(seq 1024); do
	dd if=/dev/urandom of=$mnt/sv/foo.$i bs=1M count=1 &>/dev/null
done
sync

ITERS=100
for i in $(seq $ITERS); do
	for j in $(seq 512); do
		idx=$((j*2))
		rm $mnt/sv/foo.$idx
	done
	sync
	for j in $(seq 512); do
		idx=$((j*2))
		dd if=/dev/urandom of=$mnt/sv/foo.$idx bs=1M count=1 &>/dev/null
	done
	sync
	btrfs filesystem sync $mnt
	sleep 1
	btrfs filesystem sync $mnt
done
btrfs subvol remove $mnt/sv
