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
	_umount_loop $dev
	_fresh_btrfs_mnt $dev $mnt -o discard=sync &>/dev/null
	#/mnt/repos/fstests/ltp/fsstress -d $mnt --duration=5 &>/dev/null
	#sync
}

_force_chunk_alloc() {
	local space_info=$1
	local id=$2

	while true
	do
		[ -f .done ] && break
		echo "$space_info $id: alloc a chunk!"
		echo 1 > $(_btrfs_sysfs_space_info $dev $space_info)/force_chunk_alloc
	done
}

rm .done
_setup

#_sync &
#SYNC_PID=$!

for i in $(seq 1)
do
	_force_chunk_alloc metadata $i &
	_force_chunk_alloc data $i &
done

sleep 10
touch .done
#wait $SYNC_PID
_umount_loop $dev
_ok
