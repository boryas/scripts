#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@
CG_ROOT=/sys/fs/cgroup
BAD_CG=$CG_ROOT/bad-nbr
echo "+memory +cpuset" > $CG_ROOT/cgroup.subtree_control
mkdir -p $BAD_CG
echo 0,1 > $BAD_CG/cpuset.cpus
echo $$ > $BAD_CG/cgroup.procs

dev=$1
mnt=$2
NR_FILES=10000
SZ=2G
F=$mnt/foo

_dump() {
	echo "################## DUMP $1 ##################"
	#$BTRFS filesystem usage $mnt
	$SCRIPTS_ROOT/drgn/folio-invalidate-sim.py $mnt
	grep -e '\<nr_active_file\>' /proc/vmstat
	grep -e '\<nr_inactive_file\>' /proc/vmstat
}

_setup() {
	for i in $(seq 100)
	do
		findmnt $dev >/dev/null || break
		echo "umounting $dev..."
		umount $dev
	done
	$MKFS -f -m single -d single $dev >/dev/null 2>&1
	mount -o noatime $dev $mnt
}
_setup
_dump "Fresh Mount"

_fio() {
	fio --name=foo --directory=$mnt --nrfiles=$NR_FILES --blocksize=2k --filesize=2k --rw=write --ioengine=psync --fallocate=none --create_on_open=1 --openfiles=32 --zero_buffers=1 --alloc-size=2000000 >/dev/null 2>&1
	sync
}

_fio
sync
sync
btrfs fil sync $mnt
_dump "Post Fio"

_read() {
	for i in $(seq 0 $((NR_FILES - 1)))
	do
		cat $mnt/foo.0.$i >/dev/null
	done
}
#_read
#_dump "Post Read"

_rm() {
	for i in $(seq 0 $((NR_FILES / 200 - 1)))
	do
		for j in $(seq 0 99)
		do
			rm $mnt/foo.0.$((i * 200 + j))
		done
	done
}
#_rm
#_dump "Post Rm"

echo 1 | sudo tee /proc/sys/vm/drop_caches
_dump "Post Drop Caches"

#stress -m 59 -t 10 --vm-keep
#_dump "Post Stress"
