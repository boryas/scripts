#!/usr/bin/env bash

dev="/dev/loop0"
part=$dev"p1"
mnt="/mnt/lol"

_cleanup() {
	umount $mnt >/dev/null 2>&1
	parted $dev 'mktable gpt' --script >/dev/null 2>&1
	do_mkpart >/dev/null 2>&1
	mkfs.btrfs -f $part >/dev/null 2>&1
}

trap _cleanup exit 0 1 15

do_mkpart() {
	parted $dev 'mkpart mypart 1M 100%' --script
}

do_rmpart() {
	parted $dev 'rm 1' --script
}

do_parted() {
	do_rmpart
	do_mkpart
}

parted_loop() {
	while true
	do
		do_parted >/dev/null 2>&1
		sleep 0.1
	done
}

do_mount() {
	mount $part $mnt
	umount $mnt
}

mount_loop() {
	while true
	do
		do_mount >/dev/null 2>&1
	done
}

mount_loop &
mpid=$!

parted_loop &
ppid=$!

SLEEP_SECONDS=$1
sleep $SLEEP_SECONDS

kill $mpid
wait $mpid

kill $ppid
wait $ppid
