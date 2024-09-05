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
NR_SNAP_THREADS=3
NR_REFLINK_THREADS=8

_cleanup() {
	for pid in ${pids[@]}
	do
		echo "kill spawned pid $pid"
		kill $pid
	done
	pkill fsstress
	pkill btrfs
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

_fsstress() {
	$FSSTRESS -d $sv -n 10000 -w -p 8 -l 0
	echo "fsstress exited with code $?"
}

_snap() {
	local snap="$mnt/snap.$1"

	while (true)
	do
		$BTRFS subv snap $sv $snap >/dev/null
		sleep 5
		$BTRFS subv del $snap >/dev/null
	done
}

_balance() {
	while (true)
	do
		$BTRFS -q balance start -dusage=100 $mnt || break
	done
	echo "balance loop exited"
}

_reflink() {
	local src_snap_id=$((1 + ($1 % $NR_SNAP_THREADS)))
	local tgt="$mnt/REFLINK_TGT.$src_snap_id"

	while (true)
	do
		local src=$(find $mnt/snap.$src_snap_id -type f 2>/dev/null | shuf -n1)

		[ -z "$src" ] && continue
		cp --reflink=always $src $tgt 2>/dev/null || continue
		sleep 3
		rm $tgt 2>/dev/null
	done
}

_sync() {
	while (true)
	do
		sync
		sleep 1
	done
}

echo "BO RUN REPRO" > /dev/kmsg
pids=()

_fsstress &
pids+=( $! )
echo "launched fsstress loop $!"

_balance &
balance_pid=$!
pids+=( $balance_pid )
echo "launched balance loop $balance_pid"

for i in $(seq $NR_SNAP_THREADS)
do
	_snap $i &
	pids+=( $! )
done
echo "launched $NR_SNAP_THREADS snapshot loops"

for i in $(seq $NR_REFLINK_THREADS)
do
	_reflink $i &
	pids+=( $! )
done
echo "launched $NR_REFLINK_THREADS reflink loops"

_sync &
pids+=( $! )
echo "launched sync loop $!"

wait $balance_pid
