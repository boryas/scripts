#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
mkfs.ext4 -N 16 $dev
mount -o noatime $dev $mnt

while (true); do
    $SCRIPTS_ROOT/c/atomic-update $mnt/foo || break
done

umount $dev
