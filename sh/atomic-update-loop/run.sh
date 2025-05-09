#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate.sh"
source "$SH_ROOT/fs.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
mkfs.ext4 -F -N 16 $dev
mount -o noatime $dev $mnt

i=1
NR_LOOPS=1000000
while (true); do

	printf '\r%d' $i
	if [ $i -eq $NR_LOOPS ]; then
		break;
	fi
	$SCRIPTS_ROOT/c/atomic-update $mnt/foo || break
	e2fsck $dev
	i=$((i + 1))
done
printf '\n'

umount $dev
