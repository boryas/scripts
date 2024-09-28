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
	mkdir -p $GOOD_CG
	mkdir -p $BAD_CG
	# 1 GB memory max
	echo $((64 << 20)) > $BAD_CG/memory.max
	# just one cpu
	echo 0 > $BAD_CG/cpuset.cpus

	# build the big-read command, in case it's not built
	make
}

_my_cleanup() {
	_cleanup
	umount $mnt
}

trap _my_cleanup exit 0 1 15

_setup

_victim() {
	i=0;
	while (true)
	do
		local tmp=$mnt/tmp.$((i % (1024 * 1024)))

		dd if=/dev/zero of=$tmp bs=4k count=2 >/dev/null 2>&1
		sync
		i=$((i+1))
	done
}

# 8 heavy reclaim reader tasks on one cpu
for i in $(seq 8)
do
	./big-read $mnt/biggo &
	pid=$!
	echo $pid > $BAD_CG/cgroup.procs
	PIDS+=( $pid )
done

# one victim doing lots of del_csum and sync
_victim &
pid=$!
echo $pid > $GOOD_CG/cgroup.procs
PIDS+=( $pid )

_sleep $1
