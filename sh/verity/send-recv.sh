#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate.sh"

BTRFS="/home/vmuser/btrfs-progs/btrfs"

_cleanup() {
	sudo umount -q "$mnt" || true
}

_fsv_enable() {
	local f=$1
	local tmp=$2
	local salt="deadbeef"
	sysctl fs.verity.require_signatures=1
	openssl req -newkey rsa:4096 -nodes -keyout $tmp/key.pem -x509 -out $tmp/cert.pem
	openssl x509 -in $tmp/cert.pem -out $tmp/cert.der -outform der
	keyctl padd asymmetric '' %keyring:.fs-verity < $tmp/cert.der
	#fsverity sign $f $tmp/file.sig --key=$tmp/key.pem --cert=$tmp/cert.pem --salt=$salt
	#fsverity enable $f --signature=$tmp/file.sig --salt=$salt || _fail "fsverity enable failed"
	fsverity sign $f $tmp/file.sig --key=$tmp/key.pem --cert=$tmp/cert.pem
	fsverity enable $f --signature=$tmp/file.sig || _fail "fsverity enable failed"
}

if [ $# -lt 2 ]
then
	echo "usage: send-recv.sh dev mnt" >&2
	exit 1
fi

dev=$1
mnt=$2
subv=$mnt/subv
f="$subv/f"
tmp=$mnt/tmp
stream=/tmp/fsv.ss

mkfs.btrfs -f "$dev"
mount "$dev" "$mnt"

mkdir -p $tmp
$BTRFS subvol create $subv
dd if=/dev/zero of=$f bs=4k count=3

_fsv_enable $f $tmp || _fail "fs-verity enable failed"
chmod a+x $f || _fail "chmod failed"
setcap cap_net_raw=ep $f || _fail "setcap failed"

$BTRFS property set $subv ro true || _fail "property set failed"
$BTRFS send --proto 0 -f $stream $subv || _fail "send failed"
fsverity measure $f > /tmp/measure1 || _fail "measure failed"
$BTRFS inspect-internal dump-tree $dev

umount "$dev"
mkfs.btrfs -f "$dev"
mount "$dev" "$mnt"

$BTRFS receive --dump -f $stream || _fail "recv failed"
$BTRFS receive $mnt -f $stream || _fail "recv failed"
echo 3 > /proc/sys/vm/drop_caches || _fail "drop caches failed"
fsverity measure $f > /tmp/measure2 || _fail "measure failed"

diff /tmp/measure1 /tmp/measure2 || _fail "measurement changed"

_cleanup
_ok
