#!/usr/bin/env bash
#
SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)
FSSTRESS=/home/vmuser/fstests/ltp/fsstress

source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
sv=$mnt/sv
snap=$mnt/snap
NR_FILES=100000
F=$mnt/foo

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
_dump "Fresh Mount"

# fsstress does snapshot stuff, don't need to do it ourselves
_stress() {
    $FSSTRESS -d $sv -n 1000 -w -p 8

}

# also do a bunch of balances while stressing
_balance() {
    while (true)
    do
        $BTRFS balance start -dusage=80 $mnt
    done
}

_tree_mod_log() {
    local sz=$(lsblk -nb -o SIZE /dev/tst/lol)
    while (true)
    do
        local off=$(shuf -i 0-$sz -n 1)
        $BTRFS inspect-internal logical-resolve $off >/dev/null 2>&1
    done

}

_fsstress &
fsstress_pid=$!

_balance &
balance_pid=$!

_tree_mod_log &
tree_mod_log_pid=$!

time=$3
[ -z "${$time+x}" ] && time=60
sleep $time

kill $fsstress_pid
kill $balance_pid
kill $tree_mod_log_pid
wait
