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

_log "create subv"
btrfs subvolume create $subv

_log "write a bunch of files to make multiple tree levels"
for i in $(seq 1024);
do
	dd if=/dev/zero of=$f.pad.$i bs=$PAD_FILE_SZ count=1
done
sync
# size = 1K * 16K = 16M
btrfs qgroup show $mnt

_log "write $f"
dd if=/dev/zero of=$f bs=$FILE_SZ count=2
# size = 272M
sync
btrfs qgroup show $mnt

_log "snapshot 1"
btrfs subvolume snapshot $subv $snap.1
# size = 0
btrfs qgroup show $mnt

_log "write 1"
dd if=/dev/zero of=$snap.1/fits bs=$FILE_SZ count=3
sync
btrfs qgroup show $mnt
# size = 384

_log "snapshot 2"
btrfs subvolume snapshot $subv $snap.2

sync
btrfs qgroup show $mnt

_log "rm 1"
rm "$snap.1/f"
sync
btrfs qgroup show $mnt

# interesting case, should fail or wreak havoc
#_log "rm original"
#rm "$f"

_log "rm 2"
rm "$snap.2/f"
sync
btrfs qgroup show $mnt

_log "rm original"
rm "$f"
sync
btrfs qgroup show $mnt
