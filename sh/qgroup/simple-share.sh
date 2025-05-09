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

_kmsg "create subv"
btrfs subvolume create $subv

_kmsg "write a bunch of files to make multiple tree levels"
for i in $(seq 1024);
do
	dd if=/dev/zero of=$f.pad.$i bs=$PAD_FILE_SZ count=1
done
# size = 1K * 16K = 16M

_kmsg "write $f"
dd if=/dev/zero of=$f bs=$FILE_SZ count=2
# size = 272M

_kmsg "sync"
sync

_kmsg "snapshot 1"
btrfs subvolume snapshot $subv $snap.1
# size = 0
dd if=/dev/zero of=$snap.1/fits bs=$FILE_SZ count=3
# size = 384

_kmsg "snapshot 2"
btrfs subvolume snapshot $subv $snap.2

_kmsg "sync"
sync

_kmsg "rm 1"
rm "$snap.1/f"

# interesting case, should fail or wreak havoc
#_kmsg "rm original"
#rm "$f"

_kmsg "rm 2"
rm "$snap.2/f"

_kmsg "rm original"
rm "$f"
