#!/usr/bin/env bash

set -euo pipefail

find_loop() {
	local img=$1
	losetup -a | grep $img | cut -d: -f1
}

del_loop() {
	local img=$1
	local loop=$(find_loop $img)
	umount $loop
	losetup -d $loop
	rm $img
}

mk_loop() {
	local img=$1
	del_loop $img
	dd if=/dev/zero of=$img bs=100M count=2
	losetup -f $img
	find_loop $img
}

do_seed() {
	mkdir -p $SEED_MNT
	mkfs.btrfs -f $SEED_DEV
	mount $SEED_DEV $SEED_MNT
	echo "seed things" | tee $SEED_MNT/seedfile
	dd if=/dev/zero of=$SEED_MNT/bigseedfile bs=4k count=100
	umount $SEED_DEV
	btrfstune -S 1 $SEED_DEV
}

do_sprout() {
	if [ $# -ne 2 ]
	then
		echo "do_sprout expects sprout_img, sprout_mnt"
		exit 1
	fi
	local sprout_img=$1
	local sprout_mnt=$2

	sprout_dev=$(mk_loop $sprout_img)
	echo "sprout dev: $sprout_dev"
	mkdir -p $sprout_mnt
	mount $SEED_DEV $SEED_MNT
	btrfs device add $sprout_dev $SEED_MNT
	umount $SEED_MNT
	mount $sprout_dev $sprout_mnt
	echo "sprout things" | tee $sprout_mnt/sproutfile
}

clean_loop() {
	local img=$1
	del_loop $img
	mk_loop $img
}

if [ $# -ne 1 ]
then
	echo "usage: mkseed.sh $mnt"
	exit 1
fi

SEED_MNT=$1
SEED_IMG=/tmp/seed.img
SEED_DEV=$(mk_loop $SEED_IMG)
echo "seed dev: " $SEED_DEV
do_seed

SPROUT_IMG1=/tmp/sprout1.img
SPROUT_IMG2=/tmp/sprout2.img
SPROUT_MNT1="$SEED_MNT-sprout1"
SPROUT_MNT2="$SEED_MNT-sprout2"
do_sprout $SPROUT_IMG1 $SPROUT_MNT1
do_sprout $SPROUT_IMG2 $SPROUT_MNT2
