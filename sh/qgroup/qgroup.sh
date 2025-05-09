SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
[ -z "$BTRFS" ] && source "$SH_ROOT/btrfs.sh"

_qgroup_show() {
	local mnt=$1
	$BTRFS qgroup show $mnt
}

_squota_json() {
	local mnt=$1
	echo "{ $($BTRFS qgroup show --raw $mnt | \
		grep -v Path | grep -v '\----' | \
		awk '{print "\"" $4 "\": " $3}' | \
		tr '\n' ', ' | head -c -1) }" | jq
}

_squota_subvol() {
	local mnt=$1
	local subvol=$2

	_squota_json $mnt | jq ".$subv"
}

_inspect_owned_metadata() {
	local dev=$1

	$BTRFS inspect-internal dump-tree $dev | grep leaf | awk '{print $1 " " $11}' | sort | uniq -c || echo ""
	$BTRFS inspect-internal dump-tree $dev | grep node | awk '{print $1 " " $13}' | sort | uniq -c || echo ""
}
