#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs"

FSSTRESS=/home/vmuser/fstests/ltp/fsstress

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

CG_ROOT=/sys/fs/cgroup
BAD_CG=$CG_ROOT/bad-nbr
GOOD_CG=$CG_ROOT/good-nbr
_setup() {
	_umount_loop $dev
	_fresh_btrfs_mnt $dev $mnt

	# big enough file that reading/caching it triggers reclaim
	dd if=/dev/zero of=$mnt/biggo bs=1G count=5
	sync

	echo "+memory +cpuset" > $CG_ROOT/cgroup.subtree_control
	mkdir -p $BAD_CG
	# 1 GB memory max
	echo $((64 << 20)) > $BAD_CG/memory.max
	mkdir -p $GOOD_CG

	# build the big-read command, in case it's not built
	make
}

_my_cleanup() {
	_cleanup
	umount $mnt
}

trap _my_cleanup exit 0 1 15

./big-read $mnt/biggo &
pid=$!
echo $pid > $BAD_CG/cgroup.procs
PIDS+=( $pid )

_sleep $1
