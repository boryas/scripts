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
if [ $# -ne 2 ]; then
	_err "usage: $SCRIPT <dev> <mnt> <N> <ERR_RATE>"
	_usage
fi
N=$1
ERR_RATE=$2

_setup() {
	_umount_loop $dev
	_fresh_btrfs_mnt $dev $mnt -o discard=sync &>/dev/null
	/mnt/repos/fstests/ltp/fsstress -d $mnt --duration=5 &>/dev/null
	sync
	mount -o remount,crash_post_commit,skip_extent_writes=$ERR_RATE $mnt
}

clean_mounts=0
backup_mounts=0
repairs=0
broken=0

_usebackuproot() {
	# ok, we failed; try usebackuproot
	btrfs check $dev
	mount -o ro,rescue=usebackuproot $dev $mnt || return $?
	mount -o remount,rw $mnt || return $?
	findmnt -t btrfs -O rw
	touch $mnt/foo
	sync
	touch $mnt/bar
	sync
	btrfs scrub start $mnt
	sleep 1
	btrfs scrub status $mnt
}

_repair() {
	false
}

_stats() {
	_happy "clean $clean_mounts"
	_happy "backup $backup_mounts"
	_happy "repair $repairs"
	if [ $broken -gt 0 ]; then
		_sad "broken $broken"
	fi
}

_my_cleanup() {
	_stats
	_umount_loop $dev
}

_bad_exit() {
	_my_cleanup
	exit 1
}

trap _bad_exit INT TERM

_log "Run $N attempts with $ERR_RATE% missed eb bios."
i=0
for i in $(seq $N); do
	_log "======== Attempt $i ========"
	_setup
	dd if=/dev/urandom of=$mnt/foo.$i bs=1M count=1 &>/dev/null
	sync
	# crash_post_commit error injection sets us ro
	umount $mnt
	# maybe with a completely healthy fs
	mount -o rw $dev $mnt
	if [ $? -eq 0 ]; then
		_log "cleanly mounted"
		clean_mounts=$((clean_mounts + 1))
		continue
	fi

	_usebackuproot
	if [ $? -eq 0 ]; then
		_log "backup root"
		backup_mounts=$((backup_mounts + 1))
		continue
	fi
	_repair
	if [ $? -eq 0 ]; then
		_log "repaired"
		repairs=$((repairs + 1))
		continue;
	fi

	_log "totally broken"
	broken=$((broken + 1))
done

[ $broken -gt 0 ] && _bad_exit
_my_cleanup
_ok
