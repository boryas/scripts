source "$SH_ROOT/btrfs.sh"

# Setup fresh btrfs with simple quotas
_fresh_squota_mnt() {
	local dev=$1
	local mnt=$2
	shift
	shift

	_log "fresh squota mount $@ $dev $mnt"
	$MKFS -f $dev >/dev/null || _fail "Failed to mkfs $dev"
	mount -o noatime "$@" $dev $mnt || _fail "Failed to mount $dev $mnt"
	$BTRFS quota enable --simple $mnt || _fail "Failed to enable squota on $mnt"
}

# Wait for subvolume deletions to complete
_wait_for_deletion() {
	local mnt=$1
	local max_wait=${2:-30}
	local waited=0

	# Trigger cleaner thread
	$BTRFS filesystem sync "$mnt" >/dev/null 2>&1
	sleep 1
	$BTRFS filesystem sync "$mnt" >/dev/null 2>&1

	while [ $waited -lt $max_wait ]; do
		local under_del=$($BTRFS qgroup show "$mnt" 2>/dev/null | grep -c "<under deletion>" || true)
		[ $under_del -eq 0 ] && break

		# Trigger cleaner periodically
		if [ $((waited % 5)) -eq 0 ]; then
			$BTRFS filesystem sync "$mnt" >/dev/null 2>&1
		fi

		sleep 1
		waited=$((waited + 1))
	done

	sync
}

# Check if qgroup has leaked usage (usage > 0 with no members)
_check_qgroup_leak() {
	local qgroupid=$1
	local mnt=$2

	# Check if qgroup has members
	local child_col=$($BTRFS qgroup show -pc "$mnt" 2>/dev/null | \
		awk -v qg="$qgroupid" '$1 == qg {print $5}')

	# If no members, check for usage
	if [ -z "$child_col" ] || [ "$child_col" = "-" ]; then
		local usage=$($BTRFS qgroup show --raw "$mnt" 2>/dev/null | \
			awk -v qg="$qgroupid" '$1 == qg {print $2}')

		if [ -n "$usage" ] && [ $usage -gt 0 ]; then
			_err "$qgroupid has $usage bytes but no members!"
			return 0
		fi
	fi

	return 1
}
