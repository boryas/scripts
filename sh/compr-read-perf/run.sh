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
	echo "write out $mnt/cmpr"
	dd if=/dev/zero of=$mnt/cmpr bs=1G count=4
	echo "write out $mnt/non-cmpr"
	dd if=/dev/urandom of=$mnt/non-cmpr bs=1G count=4
	sync
	echo "confirm $mnt/cmpr compression"
	compsize $mnt/cmpr
	xfs_io -c fiemap $mnt/cmpr | wc -l
	echo "confirm $mnt/non-cmpr non-compression"
	compsize $mnt/non-cmpr
	xfs_io -c fiemap $mnt/non-cmpr | wc -l
}

_do_read() {
	local f=$1
	local bs=$2

	echo 1 > /proc/sys/vm/drop_caches
	echo "dd $f $bs"
	dd if=$f of=/dev/null bs=$bs
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
	rm .re-mkfs &>/dev/null
}

_setup
_do_read $mnt/non-cmpr 4k
_do_read $mnt/non-cmpr 128k
_do_read $mnt/cmpr 4k
_do_read $mnt/cmpr 128k
