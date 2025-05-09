#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"

_cleanup() {
	sudo umount -q "$mnt" || true
}

MODE_FILE="/proc/sys/fs/verity/mode"
disable_verity() {
	echo "disable" | sudo tee "$MODE_FILE"
}
audit_verity() {
	echo "audit" | sudo tee "$MODE_FILE"
}
enforce_verity() {
	echo "enforce" | sudo tee "$MODE_FILE"
}

if [ $# -lt 4 ]
then
	echo "usage: btrfs-verity.sh dev mnt corrupt_off corrupt_sz" >&2
	exit 1
fi

dev=$1
mnt=$2
corrupt_off=$3
corrupt_sz=$4

enforce_verity

sudo umount -q "$mnt" || true
sudo mkfs.btrfs -f "$dev" >/dev/null
sudo mount "$dev" "$mnt" -o nodatasum

f="$mnt/foo"
cp "$DIR/exe" "$f"
sudo xfs_io -c sync "$mnt"
sudo fsverity enable "$f"

sha256sum "$f"

fiemap_off=$(sudo xfs_io -r -c fiemap "$f" | grep '\[' | cut -d: -f3 | awk -F '.' '{print $1}')
file_off=$(sudo btrfs-map-logical -l $((512 * fiemap_off)) "$dev" | awk '{print $4}' | head -1)
corrupt_off=$((file_off + corrupt_off))

sudo umount "$mnt"
sudo dd if=/dev/zero of="$dev" bs=1 count="$corrupt_sz" seek="$corrupt_off" 2>/dev/null
sudo mount "$dev" "$mnt" -o nodatasum

set +e
echo 3 | sudo tee /proc/sys/vm/drop_caches
"$f" && _fail "ran corrupted $f without error"
sha256sum "$f" && _fail "sha-d $f without error"

_ok
