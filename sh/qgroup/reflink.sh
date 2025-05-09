#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
PAD_FILE_SZ=16K
FILE_SZ=128M

subv="$mnt/subv"
f="$subv/f"
snap="$mnt/snap"

_fresh_btrfs_mnt $dev $mnt

btrfs quota enable $mnt

_kmsg "create subv"
btrfs subvolume create $subv

_kmsg "write $f"
dd if=/dev/zero of=$f bs=$FILE_SZ count=2
sync

_kmsg "reflink $f.ref->$f"
cp --reflink=auto $f $f.ref
sync
