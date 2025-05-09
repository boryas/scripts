#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"
source "$DIR/qgroup.sh"

_dump() {
	_squota_json $mnt
	_inspect_owned_metadata $dev | grep 25
}

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
# size = node + leaf = 32K
_dump

_log "write a bunch of files to make multiple tree levels"
for i in $(seq 1024);
do
	dd if=/dev/zero of=$f.pad.$i bs=$PAD_FILE_SZ count=1 >/dev/null 2>&1
done
sync
# size = 1K * 8K = 8M + 32K
_dump

_log "write f"
dd if=/dev/zero of=$f bs=$FILE_SZ count=2 >/dev/null 2>&1
# size = 264M + 32K
sync
_dump

_log "snapshot"
$BTRFS subvolume snapshot $subv $snap
# size = 32K
_dump

_log "touch the snapshotted file"
touch $snapped
sync
_dump
