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

_fresh_btrfs_mnt $dev $mnt -o clear_cache,space_cache=v1

_kmsg "write first 16K, 1M, 16M file"
dd if=/dev/zero of=$f.1 bs=16K count=1 # sz class = 1
dd if=/dev/zero of=$f.2 bs=1M count=1 # sz class = 2
dd if=/dev/zero of=$f.3 bs=16M count=1 # sz class = 3
sync
cat $(_btrfs_sysfs $dev)/allocation/data/size_classes

_cycle_mnt $dev $mnt

_kmsg "write second 16M file"
dd if=/dev/zero of=$f.4 bs=16M count=1 # sz class = 3
sync
cat $(_btrfs_sysfs $dev)/allocation/data/size_classes

#dmesg | tail -n 25
