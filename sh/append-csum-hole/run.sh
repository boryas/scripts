#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2

_setup() {
	[ -f .done ] && rm .done
	_umount_loop $dev
	_fresh_btrfs_mnt $dev $mnt -o compress-force=zstd:3 &>/dev/null
}

_setup

_sync() {
	echo "sync loop"
	while true
	do
		[ -f .done ] && break
		sync
		[ -f .done ] && break
		sleep 1
	done
}

_append() {
	echo "append loop"
	while true
	do
		[ -f .done ] && break
		dd if=/dev/zero of=$mnt/foo bs=8k count=1 conv=notrunc oflag=append &>/dev/null
	done
}

_read() {
	echo "read loop"
	while true
	do
		[ -f .done ] && break
		local sz=$(stat -c %s $mnt/foo)
		local skip=$(((sz >> 12) - 2))
		dd if=$mnt/foo of=/dev/null bs=4k skip=$skip count=2 iflag=direct &>/dev/null
	done
}

_drop_caches() {
	echo "drop caches loop"
	while true
	do
		[ -f .done ] && break
		echo 3 > /proc/sys/vm/drop_caches
	done
}

_sync &
SYNC_PID=$!
_read &
_append &
echo 4 > /proc/sys/vm/drop_caches
_drop_caches &
wait $SYNC_PID
_ok
