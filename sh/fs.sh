source "$SH_ROOT/boilerplate.sh"

_basic_dev_mnt_usage() {
	if [ $# -lt 2 ]
	then
		_err "usage: $SCRIPT <dev> <mnt>"
		_usage
	fi
}

_cycle_mnt() {
	local dev=$1
	local mnt=$2

	_log "cycle mount $dev $mnt" > /dev/kmsg
	umount $dev
	mount $dev $mnt
}

_umount() {
	local mnt=$1
	set +e
	umount $mnt
	set -e
}

_umount_loop() {
	local dev=$1

	for i in $(seq 100)
	do
		findmnt $dev >/dev/null || break
		_log "umounting $dev..."
		umount $dev
	done
}
