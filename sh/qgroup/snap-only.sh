#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"
source "$DIR/qgroup"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
PAD_FILE_SZ=8K
FILE_SZ=128M

subv="$mnt/subv"
f="$subv/f"
snap="$mnt/snap"
snapped="$snap/f"

_fresh_btrfs_mnt $dev $mnt >/dev/null 2>&1
btrfs quota enable $mnt

_log "create subv"
btrfs subvolume create $subv

_log "write a bunch of files to make multiple tree levels"
for i in $(seq 1024);
do
	dd if=/dev/zero of=$f.pad.$i bs=$PAD_FILE_SZ count=1 >/dev/null 2>&1
done
sync
# size = 1K * 8K = 8M
_squota_json $mnt

_log "write f"
dd if=/dev/zero of=$f bs=$FILE_SZ count=2 >/dev/null 2>&1
# size = 272M
sync
_squota_json $mnt

_log "snapshot"
$BTRFS subvolume snapshot $subv $snap
_squota_json $mnt
