#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@
dev=$1
mnt=$2
shift
shift

CG_ROOT=/sys/fs/cgroup
BAD_CG=$CG_ROOT/bad-nbr
GOOD_CG=$CG_ROOT/good-nbr
NR_BIGGOS=1
NR_LITTLE=100
NR_VICTIMS=32
NR_VILLAINS=2048

_stats() {
	echo "================"
	date
	_elapsed
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

_biggo_vol() {
	echo $mnt/biggo_vol.$1
}

_biggo_file() {
	echo $(_biggo_vol $1)/biggo
}

_subvoled_biggos() {
	total_sz=$((10 << 30))
	per_sz=$((total_sz / $NR_VILLAINS))
	dd_count=$((per_sz >> 20))
	echo "create $NR_VILLAINS subvols with a file of size $per_sz bytes for a total of $total_sz bytes."
	for i in $(seq $NR_VILLAINS)
	do
		btrfs subvol create $(_biggo_vol $i) &>/dev/null
		dd if=/dev/zero of=$(_biggo_file $i) bs=1M count=$dd_count &>/dev/null
	done
	echo "done creating subvols."
}

_setup() {
	[ -f .done ] && rm .done
	_umount_loop $dev
	if [ -f .re-mkfs ]; then
		_fresh_btrfs_mnt $dev $mnt
	else
		_btrfs_mnt $dev $mnt
	fi
	[ -f .re-mkfs ] && _subvoled_biggos
	rm .re-mkfs &>/dev/null
	_setup_cgs
}

_kill_cg() {
	local cg=$1
	local attempts=0
	_log "kill cgroup $cg"
	while true; do
		attempts=$((attempts + 1))
		echo 1 > $cg/cgroup.kill
		sleep 1
		procs=$(wc -l $cg/cgroup.procs | cut -d' ' -f1)
		[ $procs -eq 0 ] && break
	done
	_log "killed cgroup $cg in $attempts attempts"
}

_my_cleanup() {
	echo "CLEANUP!"
	_kill_cg $BAD_CG
	_kill_cg $GOOD_CG
	sleep 1
	_cleanup
	rmdir $BAD_CG
	rmdir $GOOD_CG
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
	local i=$1
	echo $BASHPID > $BAD_CG/cgroup.procs
	$DIR/big-read $(_biggo_file $i)
}

# Hit del_csum a lot by overwriting lots of small new files
_victim() {
	echo $BASHPID > $GOOD_CG/cgroup.procs
	i=0;
	while (true)
	do
		local tmp=$mnt/tmp.$i

		dd if=/dev/zero of=$tmp bs=4k count=2 >/dev/null 2>&1
		i=$((i+1))
		[ $i -eq $NR_LITTLE ] && i=0
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
	syncs=0
	echo $BASHPID > $GOOD_CG/cgroup.procs
	while true
	do
		[ -f .done ] && break
		_one_sync
		syncs=$((syncs + 1))
		[ -f .done ] && break
		sleep 10
	done
	if [ $syncs -eq 0 ]; then
		echo "do at least one sync!"
		_one_sync
	fi
	echo "sync loop done."
}

echo "start $NR_VILLAINS villains"
for i in $(seq $NR_VILLAINS)
do
	_villain $i &
	disown # get rid of annoying log on kill (done via cgroup anyway)
done

echo "start $NR_VICTIMS victims"
for i in $(seq $NR_VICTIMS)
do
	_victim &
	disown # get rid of annoying log on kill (done via cgroup anyway)
done

_sync &
SYNC_PID=$!

_sleep $1
_elapsed
touch .done
wait $SYNC_PID
_ok
