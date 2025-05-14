#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs.sh"

FSSTRESS=/home/vmuser/fstests/ltp/fsstress

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

CG_ROOT=/sys/fs/cgroup
BAD_CG=$CG_ROOT/bad-nbr
GOOD_CG=$CG_ROOT/good-nbr
NR_BIGGOS=1
NR_VICTIMS=32
NR_VILLAINS=512

_stats() {
	echo "================"
	date
	_elapsed
	free -h
	cat $(_btrfs_sysfs $dev)/commit_stats
	cat $BAD_CG/memory.pressure
}

_setup_cgs() {
	echo "+memory +cpuset" > $CG_ROOT/cgroup.subtree_control
	mkdir -p $GOOD_CG
	mkdir -p $BAD_CG
	#echo $((64 << 20)) > $BAD_CG/memory.max
	echo max > $BAD_CG/memory.max
	echo $((1 << 30)) > $BAD_CG/memory.high

	# just one cpu
	echo 0 > $GOOD_CG/cpuset.cpus
	echo 0,1,2,3 > $BAD_CG/cpuset.cpus
}

_write_biggos() {
	# big enough files that reading/caching them triggers reclaim
	for i in $(seq $NR_BIGGOS)
	do
		dd if=/dev/zero of=$mnt/biggo.$i bs=1M count=10240
		#dd if=/dev/zero of=$mnt/biggo.$i bs=1M count=1
	done
	sync
	# drop caches after initial write for good measure
	echo 3 > /proc/sys/vm/drop_caches
}

_setup() {
	[ -f .done ] && rm .done
	#_umount_loop $dev
	#_fresh_btrfs_mnt $dev $mnt
	_btrfs_mnt $dev $mnt
	_setup_cgs
	#_write_biggos
}

_kill_cg() {
	local cg=$1
	_log "kill cgroup $cg"
	wc -l $cg/cgroup.procs
	echo 1 > $cg/cgroup.kill
	wc -l $cg/cgroup.procs
}

_my_cleanup() {
	echo "CLEANUP!"
	_kill_cg $BAD_CG
	_kill_cg $GOOD_CG
	sleep 1
	_cleanup
	rmdir $BAD_CG
	rmdir $GOOD_CG
	_one_sync
	_stats
	umount $mnt
}


_bad_exit() {
	_err "Unexpected Exit! $?"
	_stats
	exit $?
}

trap _my_cleanup EXIT
trap _bad_exit INT TERM

_setup

# Use a lot of page cache reading the big file
_villain() {
	local i=$(shuf -i 1-$NR_BIGGOS -n 1)
	local t=$(shuf -i 1-5 -n 1)
	echo $BASHPID > $BAD_CG/cgroup.procs
	while (true)
	do
		local skip=$(($(shuf -i 0-9 -n 1) * 1024))
		dd if=$mnt/biggo.$i of=/dev/null bs=1M skip=$skip count=1024 >/dev/null 2>&1
		sleep "0.$t"
	done
}

# Hit del_csum a lot by touching lots of small new files
_victim() {
	echo $BASHPID > $GOOD_CG/cgroup.procs
	i=0;
	while (true)
	do
		local tmp=$mnt/tmp.$i

		dd if=/dev/zero of=$tmp bs=4k count=2 >/dev/null 2>&1
		i=$((i+1))
	done
}

_one_sync() {
	echo "sync..."
	before=$(date +%s)
	sync
	after=$(date +%s)
	echo "sync done in $((after - before))s"
	_stats
}

# sync in a loop
_sync() {
	echo "start sync loop"
	echo $BASHPID > $GOOD_CG/cgroup.procs
	while true
	do
		[ -f .done ] && break
		_one_sync
		sleep 10
	done
	echo "end sync loop; run final sync."
	_one_sync
	echo "sync loop fully done."
}

echo "start $NR_VILLAINS villains"
for i in $(seq $NR_VILLAINS)
do
	_villain &
done

echo "start $NR_VICTIMS victims"
for i in $(seq $NR_VICTIMS)
do
	_victim &
done

_sync &
SYNC_PID=$!

_sleep $1
_elapsed
touch .done
wait $SYNC_PID
_ok
