#!/usr/bin/env bash

MNT=".mnt"
mkdir -p $MNT

do_one() {
	local mode=$1
	shift
	local cmd=$@

	if [ $mode == "unshare" ]; then
		unshare -U -r $cmd
	else
		sudo $cmd
	fi
}

loop() {
	local img="btrfs.img"
	truncate -s1G $img
	sudo losetup -f "$img" --show
}

run_btrfs() {
	local loopdev=$(loop)
	sudo mkfs.btrfs -f $loopdev
	sudo mount $loopdev $MNT
	sudo chown $USER:$USER $MNT
	do_one $@
	sudo umount $MNT
	sudo losetup -d $loopdev
}

squota() {
	btrfs quota enable --simple $MNT
	btrfs qgroup show $MNT
	dd if=/dev/zero of=$MNT/foo bs=4k count=3
	sync
	btrfs qgroup show $MNT
}

MODE=$1
SCRIPT=$2
run_btrfs $@ $MNT
