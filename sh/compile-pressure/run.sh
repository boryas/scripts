#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

FSSTRESS=/home/vmuser/fstests/ltp/fsstress

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

_setup() {
	for i in $(seq 100)
	do
		findmnt $dev >/dev/null || break
		echo "umounting $dev..."
		umount $dev
	done
	$MKFS -f -m single -d single $dev >/dev/null 2>&1
	mount -o noatime $dev $mnt
	cd $mnt
	git clone https://github.com/torvalds/linux.git
}

_cleanup() {
	for pid in ${pids[@]}
	do
		echo "kill spawned pid $pid"
		kill $pid
	done
	pkill fsstress
	wait
	umount $mnt
	btrfs check $dev
}
trap _cleanup exit 0 1 15

_compile_loop() {
	cd $mnt/linux
	make defconfig
	while (true)
	do
		make clean
		make -j32
	done
}

_fsstress() {
	$FSSTRESS -d $mnt -n 10000 -w -p 8 -l 0
	echo "fsstress exited with code $?"
}

_setup

pids=()
_compile_loop &
pids+=( $! )
echo "launched compile loop $!"

_fsstress &
pids+=( $! )
echo "launched fsstress loop $!"

_sleep $1
