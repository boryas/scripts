#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2

_fresh_btrfs_mnt $dev $mnt

cat << EOF > big-fs.fio
[big-fs]
directory=$mnt
nrfiles=100000
readwrite=write
filesize=4k
openfiles=100
EOF

fio big-fs.fio --alloc-size=1024k
xfs_io -c 'fsync' $mnt/big-fs.0.0 &
xfs_io -c 'fsync' $mnt/big-fs.0.99999 &
sleep 1
dmesg | tail
umount $mnt
