#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

dev=$1
mnt=$2
mkdir -p $mnt
sv=$mnt/sv
NR_FILES=100000
F=$mnt/foo

_cleanup() {
	for pid in ${pids[@]}
	do
		echo "kill spawned pid $pid"
		kill $pid
	done
	pkill fsstress
	wait
	sleep 1
	umount $mnt
}
trap _cleanup exit 0 1 15

_setup() {
	for i in $(seq 100)
	do
		findmnt $dev >/dev/null || break
		echo "umounting $dev..."
		umount $dev
	done
	$MKFS -f -m single -d single $dev >/dev/null 2>&1
	mount -o noatime $dev $mnt
	$BTRFS subvol create $sv
}
_setup

# fsstress does snapshot stuff, don't need to do it ourselves
_fsstress() {
	$FSSTRESS -d $sv -n 10000 -w -p 8 -l 0
	echo "fsstress exited with code $?"
}

_snap() {
	local snap="$mnt/snap.$1"

	while (true)
	do
		$BTRFS subv snap $sv $snap >/dev/null 2>&1
		$BTRFS filesystem sync $mnt
		sync
		sleep 1
		$BTRFS subv del $snap >/dev/null 2>&1
	done
}

# also do a bunch of balances while stressing
_balance() {
	while (true)
	do
		$BTRFS balance start -dusage=80 $mnt >/dev/null 2>&1
	done
}

_reflink() {
	local tgt="$mnt/REFLINK_TGT"

	while (true)
	do
		local src=$(find $mnt -type f 2>/dev/null | shuf -n1)

		[ -f $src ] && [ -f $tgt ] || continue
		cp --reflink=always $src $tgt
		sleep 1
		sync
		rm $tgt
	done
}

echo "BO RUN REPRO" > /dev/kmsg
pids=()

_fsstress &
pids+=( $! )
echo "launched fsstress loop $!"

_balance &
pids+=( $! )
echo "launched balance loop $!"

NR_SNAP_THREADS=8
for i in $(seq $NR_SNAP_THREADS)
do
	_snap $i &
	pids+=( $! )
	echo "launched snap loop $!"
done

NR_REFLINK_THREADS=128
for i in $(seq $NR_REFLINK_THREADS)
do
	_reflink $i &
	pids+=( $! )
	echo "launched reflink loop $!"
done

time=$3
[ -z "${time+x}" ] && time=60
echo "SLEEP $time"
sleep $time
