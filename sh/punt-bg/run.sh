#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

_setup() {
	_umount_loop $dev
	mount -o noatime,discard $dev $mnt
}

trap _cleanup EXIT

F=$mnt/foo

_setup
dd if=/dev/zero of=$F bs=128k count=3
sync

rm $F
btrfs filesystem sync $mnt
sleep 1
btrfs filesystem sync $mnt
sleep 1

mount -o remount,discard=async $mnt
