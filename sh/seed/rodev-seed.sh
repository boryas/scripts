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

do_ro() {
	mkdir -p $RO_MNT
	mkfs.btrfs -f $RO_DEV
	mount $RO_DEV $RO_MNT
	echo "ro things" | tee $RO_MNT/rofile
	dd if=/dev/zero of=$RO_MNT/bigrofile bs=4k count=100
	umount $RO_DEV
	btrfs property set -t device $RO_DEV ro true
}

do_rw() {
	if [ $# -ne 2 ]
	then
		echo "do_rw expects rw_img, rw_mnt"
		exit 1
	fi
	local rw_img=$1
	local rw_mnt=$2

	rw_dev=$(mk_loop $rw_img)
	echo "rw dev: $rw_dev"
	mkdir -p $rw_mnt
	mount $RO_DEV $RO_MNT
	btrfs device add $rw_dev $RO_MNT
	umount $RO_MNT
	mount $rw_dev $rw_mnt
	echo "rw things" | tee $rw_mnt/rwfile
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

RO_MNT=$1
RO_IMG=/tmp/seed.img
RO_DEV=$(mk_loop $RO_IMG)
echo "ro dev: " $RO_DEV
do_ro
exit 0

RW_IMG1=/tmp/rw1.img
RW_IMG2=/tmp/rw2.img
RW_MNT1="$RO_MNT-rw1"
RW_MNT2="$RO_MNT-rw2"
do_rw $RW_IMG1 $RW_MNT1
do_rw $RW_IMG2 $RW_MNT2
