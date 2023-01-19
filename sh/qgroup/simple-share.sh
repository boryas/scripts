#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
FILE_SZ=8M

subv="$mnt/subv"
f="$subv/f"
snap="$mnt/snap"

_fresh_btrfs_mnt $dev $mnt

_kmsg "create subv"
btrfs subvolume create $subv

_kmsg "write $f"
dd if=/dev/zero of=$f bs=$FILE_SZ count=1

_kmsg "sync"
sync

_kmsg "snapshot 1"
btrfs subvolume snapshot $subv $snap.1

_kmsg "snapshot 2"
btrfs subvolume snapshot $subv $snap.2

_kmsg "sync"
sync

_kmsg "rm 1"
rm "$snap.1/f"

_kmsg "rm original"
rm "$f"

_kmsg "rm 2"
rm "$snap.2/f"
