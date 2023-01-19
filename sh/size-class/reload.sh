#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
f=$mnt/f

_fresh_btrfs_mnt $dev $mnt

dd if=/dev/zero of=$f bs=1M count=1 # sz class = 2

_cycle_mount $dev $mnt

dmesg | tail -n 25
