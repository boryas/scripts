#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

#_basic_dev_mnt_usage $@
dev=$1
mnt=$2
mkdir -p $mnt
sv=$mnt/sv
snap=$mnt/snap
NR_FILES=100000
F=$mnt/foo

_cleanup() {
	kill $fsstress_pid
	kill $balance_pid
	kill $snap_pid
	kill $reflink_pid
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
	while (true)
	do
		local src=$(find $mnt -type f 2>/dev/null | shuf -n1)
		local tgt=$mnt/REFLINK_TGT

		[ -f $src ] && [ -f $tgt ] || continue
		cp --reflink=always $src $tgt
		sleep 1
		sync
		rm $tgt
	done
}

_tree_mod_log() {
	local sz=$(lsblk -nb -o SIZE $dev)
	echo $sz
	while (true)
	do
		local off=$(shuf -i 0-$sz -n 1)
		$BTRFS inspect-internal logical-resolve $off $mnt >/dev/null 2>&1
	done
}

_fsstress &
fsstress_pid=$!
echo "launched fsstress loop $fsstress_pid"

_balance &
balance_pid=$!
echo "launched balance loop $balance_pid"

_snap &
snap_pid=$!
echo "launched snap loop $snap_pid"

_reflink &
reflink_pid=$!
echo "launched reflink loop $reflink_pid"

time=$3
[ -z "${time+x}" ] && time=60
echo "SLEEP $time"
sleep $time
