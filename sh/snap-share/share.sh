#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"

if [ $# -lt 2 ]
then
	echo "usage: share.sh dev mnt" >&2
	exit 1
fi

dev=$1
mnt=$2

subv=$mnt/subv
snap=$mnt/snap

f=$subv/f
fcopy=$subv/fcopy
fsnap=$snap/f

set +e
umount $dev
set -e

mkfs.btrfs -f $dev
mount $dev $mnt

btrfs subv create $subv
dd if=/dev/zero of=$f bs=4K count=3
btrfs subv snap $subv $snap
cp $f $fcopy

umount $mnt
mount $dev $mnt

echo "read file" > /dev/kmsg
sha256sum $f
echo "read file snap" > /dev/kmsg
sha256sum $fsnap
echo "read file copy" > /dev/kmsg
sha256sum $fcopy

echo "unshare" > /dev/kmsg
dd if=/dev/urandom of=$f bs=4K seek=1 count=1 conv=notrunc
