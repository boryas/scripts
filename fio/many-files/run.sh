#!/usr/bin/env bash

set -euo pipefail

DEV=/dev/tst/lol
MNT=/mnt/lol

analyze() {
	btrfs inspect-internal dump-tree $DEV > tree.txt
	grep -e 'node .* level [12]' tree.txt > nodes.txt
}

_cleanup() {
	umount $MNT
	pkill dmesg
	exit $status
}
status=1
trap _cleanup 0 1 2 3 15

_dmesg() {
	dmesg -TW | grep -e "BO:" -e "DISOWN" > dmesg.txt
}


mkfs.btrfs -f $DEV
mount $DEV $MNT
fio --alloc-size=32M --directory=$MNT many-files.fio
sync

while (true); do
	btrfs subvolume snapshot $MNT $MNT/snap1
	fio --alloc-size=32M --directory=$MNT/snap1 many-files.fio
	btrfs subvolume snapshot $MNT/snap1 $MNT/snap2
	btrfs balance start -dusage=80 $MNT
	btrfs subvolume delete $MNT/snap1 $MNT/snap2
	umount $MNT
	btrfs check $DEV || exit 1
	mount $DEV $MNT
done

status=0
