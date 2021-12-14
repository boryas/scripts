#!/bin/sh

# generate fragmentation in btrfs with a targeted selection of intentional
# writes/fallocates

DEV=$1
MNT=$2
DIR=$MNT/enospc
FALLOC_F=$DIR/falloc
BUFF_F=$DIR/buff
SEEK=0

remove_unused() {
	sync
	sleep 30
}

usage() {
	sudo btrfs fil usage -b $MNT | grep 'Data,single'
}

one_falloc() {
	echo "falloc"
	fallocate -l1G $FALLOC_F
	sync
}

rm_falloc() {
	echo "rm falloc"
	rm $FALLOC_F
	sync
}

one_buff() {
	echo "buff $SEEK"
	dd if=/dev/zero of=$BUFF_F bs=64k count=1 conv=notrunc,fdatasync seek=$SEEK >/dev/null 2>&1
	SEEK=$(($SEEK + 1))
	sync
}

rm_buff() {
	echo "rm buff"
	rm $BUFF_F
	sync
}

echo "start"
usage

one_falloc
usage

one_buff
usage

rm_falloc
usage

one_buff
usage

remove_unused
echo "end"
usage
