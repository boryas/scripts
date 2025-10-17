#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2

_setup() {
	_umount_loop $dev
	_fresh_btrfs_mnt $dev $mnt &>/dev/null
	for i in $(seq 16); do
		fallocate -l 256M $mnt/reloc.$i
	done
	sync
	echo 50 > $(_btrfs_sysfs_space_info $dev data)/bg_reclaim_threshold
	for i in $(seq 16); do
		if [ $((i % 4)) -eq 0 ]; then
			continue
		fi
		rm $mnt/reloc.$i
	done
	btrfs fi sync $mnt
	sleep 1
	btrfs fi sync $mnt
}

_setup
sz=$(lsblk /dev/tst/lol -o size -n -b)
sz_g=$((sz >> 30))

# allocate almost all of it
echo "falloc $((sz_g - 10)) 1G files"
for i in $(seq $((sz_g - 10))); do
	fallocate -l1G $mnt/alloc.$i
done

echo "falloc 5 more 1G files"
for i in $(seq 5); do
	fallocate -l1G $mnt/last.$i &
done

echo "falloc a 10G file"
fallocate -l10G $mnt/wontwork &

sleep 0.5

echo "remove the last 5"
for i in $(seq 5); do
	rm $mnt/last.$i
done
sync
