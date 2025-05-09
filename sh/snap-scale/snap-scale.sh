#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 4 ]
then
	echo "usage: snap-scale.sh dev mnt <n|q|s> nr-files nr-snaps" >&2
	exit 1
fi

dev=$1
mnt=$2
mode=$3
nr_files=$4
nr_snaps=$5


subv=$mnt/subv
snaps=$mnt/snaps

set +e
umount $dev
set -e

[[ $mode == "n" ]] && mkfs_opts=""
[[ $mode == "q" ]] && mkfs_opts="-O quota"
[[ $mode == "s" ]] && mkfs_opts="-O squota"

$MKFS -f $mkfs_opts $dev
mount $dev $mnt
$BTRFS subv create $subv
mkdir -p $snaps

_write_files() {
    prefix=$1
    loops=$2

    for k in $(seq $loops)
    do
        for i in $(seq $nr_files)
        do
            dd if=/dev/zero of=$subv/$prefix.$i bs=4k count=2 >/dev/null 2>&1
        done
        sync
    done
}

_write_files "f" 1

# take snaps
for i in $(seq $nr_snaps)
do
    btrfs subvol snap $subv $snaps/snap.$i >/dev/null 2>&1
done

# overwrites
_overwrites() {
    for i in $(seq $nr_snaps)
    do
        for j in $(seq $nr_files)
        do
            dd if=/dev/zero of=$subv/f.$i bs=4k count=1 conv=notrunc >/dev/null 2>&1
        done
        sync
    done
}

_overwrites &
time _write_files "g" $nr_snaps
