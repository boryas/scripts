#!/usr/bin/env bash
# Parallel reproducer for btrfs squota leak with 2-level qgroup hierarchy
# Bug: Level 1 qgroups retain metadata usage after all members are removed

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/squota.sh"

if [ $# -lt 4 ]; then
	_err "usage: $SCRIPT <dev> <mnt> <duration_seconds> <num_workers>"
	_usage
fi

dev=$1
mnt=$2
duration=${3:-60}
num_workers=${4:-4}

# Worker: Creates Q1X hierarchy, snapshots, then cleans up repeatedly
worker_qgroup_churn() {
	local worker_id=$1
	local level2_qgroup=$2
	local base_subvol=$3
	local flag_file=/tmp/btrfs-worker-${worker_id}.run
	touch $flag_file

	local counter=0
	while [ -f $flag_file ]; do
		local level1_qgroup=1/$((100 + worker_id * 1000 + counter))

		# Create Q1X and assign to Q2
		$BTRFS qgroup create $level1_qgroup $mnt 2>/dev/null || continue
		$BTRFS qgroup assign $level1_qgroup $level2_qgroup $mnt 2>/dev/null || continue

		# Create intermediate snapshot and assign to Q1X
		local intermediate=$mnt/worker${worker_id}_inter_${counter}
		$BTRFS subvolume snapshot $base_subvol $intermediate >/dev/null 2>&1 || continue

		local inter_id=$($BTRFS subvolume show $intermediate 2>/dev/null | grep 'Subvolume ID:' | awk '{print $3}')
		[ -z "$inter_id" ] && continue
		$BTRFS qgroup assign 0/$inter_id $level1_qgroup $mnt 2>/dev/null || continue

		# Create working snapshots with --inherit Q1X
		for i in 1 2 3; do
			local snap=$mnt/worker${worker_id}_snap_${counter}_${i}
			$BTRFS subvolume snapshot -i $level1_qgroup $intermediate $snap >/dev/null 2>&1 || true
		done

		# Delete working snapshots (auto-removes from Q1X)
		for i in 1 2 3; do
			$BTRFS subvolume delete $mnt/worker${worker_id}_snap_${counter}_${i} 2>/dev/null || true
		done

		# Delete intermediate and remove from Q1X
		$BTRFS qgroup remove 0/$inter_id $level1_qgroup $mnt 2>/dev/null || true
		$BTRFS subvolume delete $intermediate 2>/dev/null || true

		# Cleanup Q1X
		$BTRFS qgroup remove $level1_qgroup $level2_qgroup $mnt 2>/dev/null || true
		$BTRFS qgroup destroy $level1_qgroup $mnt 2>/dev/null || true

		counter=$((counter + 1))
	done
}

# Cleanup function
cleanup() {
	_log "stopping workers"
	rm -f /tmp/btrfs-worker-*.run 2>/dev/null || true
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Setup
_umount_loop $dev
_fresh_squota_mnt $dev $mnt -o compress=zstd

# Create Q2 (level 2 persistent qgroup)
_log "create Q2 (level 2)"
level2_qgroup=2/100
$BTRFS qgroup create $level2_qgroup $mnt

# Create base image subvolume
_log "create base subvolume"
base_subvol=$mnt/base_image
$BTRFS subvolume create $base_subvol >/dev/null
base_id=$($BTRFS subvolume show $base_subvol | grep 'Subvolume ID:' | awk '{print $3}')
$BTRFS qgroup assign 0/$base_id $level2_qgroup $mnt

# Populate base with some data
_log "populate base with data"
mkdir -p $base_subvol/data
for i in $(seq 20); do
	dd if=/dev/urandom of=$base_subvol/data/file$i bs=4k count=5 2>/dev/null
done
sync

# Launch workers
_log "launching $num_workers workers for ${duration}s"
for i in $(seq $num_workers); do
	worker_qgroup_churn $i $level2_qgroup $base_subvol &
done

# Run for duration
sleep $duration

# Stop workers
_log "stopping workers"
rm -f /tmp/btrfs-worker-*.run
wait

# Wait for all deletions to complete
_log "waiting for deletions to complete"
_wait_for_deletion $mnt 60

# Check for bug
_log "checking for leaked qgroups"
$BTRFS qgroup show -pc $mnt

bug_found=0
for qg in $($BTRFS qgroup show $mnt 2>/dev/null | grep '^1/' | awk '{print $1}'); do
	if _check_qgroup_leak $qg $mnt; then
		_sad "BUG: $qg has leaked usage!"
		bug_found=1
	fi
done

if [ $bug_found -eq 1 ]; then
	_sad "BUG REPRODUCED with parallel workload!"
	exit 0
else
	_happy "No bug found"
	exit 1
fi
