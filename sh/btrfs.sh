source "$SH_ROOT/fs.sh"

MKFS=mkfs.btrfs
BTRFS=btrfs
FSTESTS=/fstests
FSSTRESS=$FSTESTS/ltp/fsstress

_fresh_btrfs_mnt() {
	local dev=$1
	local mnt=$2
	shift
	shift

	_log "fresh mount $@ $dev $mnt"
	$MKFS -f -m single -d single $dev >/dev/null || _fail "Failed to mkfs $dev"
	_btrfs_mnt "$@" $dev $mnt
}

_btrfs_mnt() {
	local dev=$1
	local mnt=$2
	shift
	shift
	mount -o noatime "$@" $dev $mnt || _fail "Failed to mount $dev $mnt"
}

_btrfs_uuid() {
	local dev=$1

	$BTRFS fi show $dev | grep uuid: | awk '{print $4}'
}

_btrfs_sysfs() {
	local dev=$1

	echo /sys/fs/btrfs/$(_btrfs_uuid $dev)
}

_btrfs_sysfs_space_info() {
	local dev=$1
	local type=$2

	echo $(_btrfs_sysfs $dev)/allocation/$type
}
