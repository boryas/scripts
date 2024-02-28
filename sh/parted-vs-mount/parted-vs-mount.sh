#!/usr/bin/env bash

DIR=/home/vmuser
MYMOUNT=$DIR/my-mount
IMG0=$DIR/img0
IMG1=$DIR/img1
IMG2=$DIR/img2
DEV0="/dev/loop0"
PART=$DEV0"p1"
MYPART=/tmp/mypart
DEV1="/dev/loop1"
MNT="/mnt/lol"
BIND="/mnt/bind"
DEV2="/dev/loop2"

_cleanup() {
	umount $MNT >/dev/null 2>&1
	umount $BIND >/dev/null 2>&1
	losetup -D
	rm $IMG0
	rm $IMG1
	rm $IMG2
	rm $MYPART
}

trap _cleanup exit 0 1 15

do_mkpart() {
	local dev=$1
	parted $dev 'mkpart mypart 1M 100%' --script
}

do_rmpart() {
	local dev=$1
	parted $dev 'rm 1' --script
}

truncate -s 5G $IMG0
truncate -s 5G $IMG1
truncate -s 5G $IMG2

losetup -f $IMG0
losetup -f $IMG1
losetup -f $IMG2
mkdir -p $MNT
mkdir -p $BIND

parted $DEV0 'mktable gpt' --script >/dev/null 2>&1
parted $DEV1 'mktable gpt' --script >/dev/null 2>&1
do_mkpart $DEV0 >/dev/null 2>&1
do_mkpart $DEV1 >/dev/null 2>&1

# mkfs with two devices to avoid clearing devices on close
# single raid to allow removing DEV2
mkfs.btrfs -f -msingle -dsingle $PART $DEV2 >/dev/null 2>&1
mount $PART $MNT
umount $MNT

# swap the partition dev_ts
do_rmpart $DEV0
do_rmpart $DEV1
do_mkpart $DEV1 >/dev/null 2>&1
do_mkpart $DEV0 >/dev/null 2>&1

# mount with mismatched dev_t!
mount $PART $MNT

# remove extra device to bring temp-fsid back in the fray
btrfs device remove $DEV2 $MNT

# non-matching name for spooky mount
ln -s $PART $MYPART

# version of mount that doesn't resolve symlinks
$MYMOUNT $MYPART $BIND

# at this point, $MNT and $BIND are separate fs-es mounting the same device.
btrfs filesystem show $MNT
btrfs filesystem show $BIND

# now do some fuckery to prove it
for i in $(seq 100); do
	dd if=/dev/urandom of=/mnt/lol/foo.$i bs=50M count=1
done
for i in $(seq 100); do
	dd if=/dev/urandom of=/mnt/bind/foo.$i bs=50M count=1
done
sync
for i in $(seq 100); do
	rm /mnt/bind/foo.$i
done
sync
fstrim -v /mnt/bind
sleep 5
echo 3 > /proc/sys/vm/drop_caches
btrfs scrub start -B /mnt/lol
