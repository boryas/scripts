#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

set -x
SZ=$(lsblk $dev -nb -o SIZE)
GAP=$((1<<30))
FILLER_SZ=$((SZ - GAP))
NR_LITTLE=1024
MID_SZ=$((1<<19)) # 512K
LITTLE_SZ=$((5 * 1024))
set +x

echo "fallocate most of the fs"
$MKFS -f -m single -d single $dev >/dev/null
mount -o noatime,compress-force=zstd:3 $dev $mnt
fallocate -l $FILLER_SZ $mnt/filler
sync
btrfs fi usage $mnt

echo "write $NR_LITTLE $MID_SZ and $LITTLE_SZ files"
# generate severe fragmentation to make enospc happen in btrfs_reserve_extent()
for i in $(seq $NR_LITTLE)
do
	dd if=/dev/zero of=$mnt/mid.$i bs=$MID_SZ count=1
	dd if=/dev/zero of=$mnt/little.$i bs=$LITTLE_SZ count=1
done
sync

echo "delete the little ones"
for i in $(seq $NR_LITTLE)
do
	rm $mnt/little.$i
done
sync

#/mnt/repos/scripts/c/gen-frag $mnt $NR_LITTLE

echo "copy in the kernel tree"
# should enospc and thus leak
btrfs subvol create $mnt/linux
i=0
while (true)
do
	#dd if=/dev/zero of=/mnt/lol/f.$i bs=100M count=1 || rm /mnt/lol/f.$i
	cp -r /mnt/repos/linux/vmlinux $mnt/linux/vmlinux.$i || rm $mnt/linux/vmlinux.$i
	sync
	i=$((i+1))
done
