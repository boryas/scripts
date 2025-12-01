#!/usr/bin/env bash
# Minimal reproducer for btrfs squota leak with 2-level qgroup hierarchy
# Bug: Level 1 qgroups retain metadata usage after all members are removed

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/squota.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2

# Unmount and remount fresh
_umount_loop $dev
_fresh_squota_mnt $dev $mnt

# Create 2-level qgroup hierarchy
_log "create Q2 (level 2)"
$BTRFS qgroup create 2/100 $mnt

_log "create Q11 (level 1)"
$BTRFS qgroup create 1/100 $mnt
$BTRFS qgroup assign 1/100 2/100 $mnt

# Create base subvolume and add to Q2
_log "create base subvolume"
$BTRFS subvolume create $mnt/base >/dev/null
base_id=$($BTRFS subvolume show $mnt/base | grep 'Subvolume ID:' | awk '{print $3}')
$BTRFS qgroup assign 0/$base_id 2/100 $mnt

# Create intermediate snapshot and add to Q11
_log "create intermediate snapshot"
$BTRFS subvolume snapshot $mnt/base $mnt/intermediate >/dev/null
inter_id=$($BTRFS subvolume show $mnt/intermediate | grep 'Subvolume ID:' | awk '{print $3}')
$BTRFS qgroup assign 0/$inter_id 1/100 $mnt

# Create snapshot from intermediate with --inherit (auto-adds to Q11)
_log "create working snapshot with --inherit 1/100"
$BTRFS subvolume snapshot -i 1/100 $mnt/intermediate $mnt/snap >/dev/null

sync; sleep 1

# Delete snapshot (should auto-remove from Q11)
_log "delete working snapshot"
$BTRFS subvolume delete $mnt/snap >/dev/null

_wait_for_deletion $mnt

# Delete intermediate and remove from Q11
_log "delete intermediate snapshot"
$BTRFS qgroup remove 0/$inter_id 1/100 $mnt
$BTRFS subvolume delete $mnt/intermediate >/dev/null

_wait_for_deletion $mnt

# Check for bug: Does Q11 have usage with no members?
_log "checking for leaked usage in 1/100"
$BTRFS qgroup show -pc $mnt

if _check_qgroup_leak 1/100 $mnt; then
	_sad "BUG REPRODUCED: 1/100 has leaked usage!"
	exit 0
else
	_happy "No bug found"
	exit 1
fi
