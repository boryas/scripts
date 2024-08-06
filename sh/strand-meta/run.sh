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
NR_FILES=10000
SZ=2G
F=$mnt/foo

for i in $(seq 100)
do
	findmnt $dev >/dev/null || break
	echo "umounting $dev..."
	umount $dev
done
$MKFS -f -m single -d single $dev >/dev/null 2>&1
mount $dev $mnt

_dump() {
	echo "################## DUMP $1 ##################"
	#$BTRFS filesystem usage $mnt
	$SCRIPTS_ROOT/drgn/bad-btrfs-cache.py
	grep -e '\<nr_active_file\>' /proc/vmstat
	grep -e '\<nr_inactive_file\>' /proc/vmstat
}

_dump "Fresh Mount"

fio --name=foo --directory=$mnt --nrfiles=$NR_FILES --blocksize=2k --filesize=2k --rw=write --ioengine=psync --fallocate=none --create_on_open=1 --openfiles=32 --zero_buffers=1 --alloc-size=2000000 >/dev/null 2>&1
sync

_dump "Post Fio & Sync"

for i in $(seq 0 $((NR_FILES / 200 - 1)))
do
	for j in $(seq 0 99)
	do
		#echo "i $i j $j"
		#echo "i * 200 + j: " $((i * 10 + j))
		rm $mnt/foo.0.$((i * 200 + j))
	done
done

_dump "Post Rm"

echo 1 | sudo tee /proc/sys/vm/drop_caches

_dump "Post Drop Caches"
