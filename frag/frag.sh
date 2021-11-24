#!/bin/sh

# generate fragmentation in btrfs with fallocate and small buffered append writes

DEV=$1
MNT=$2
TIME=$3

DIR=$MNT/enospc

do_falloc() {
	local i=0
	while (true)
	do
		local slot=$(($i % 10))
		local f=$DIR/falloc-$slot
		fallocate -l1G $f
		if [ $(($i % 100)) -eq 0 ]
		then
			local del_slot=$(( ($i / 100) % 10 ))
			#echo "FALLOC-DEL $i $del_slot"
			rm $DIR/falloc-$del_slot
		fi
		i=$(($i+1))
	done
}

do_oappend() {
	local log=$DIR/log
	local i=0
	while (true)
	do
		#if [ $(($i % 100)) -eq 0 ]
		#then
			#echo "OAPPEND $i"
		#fi
		dd if=/dev/zero of=$log bs=4k count=1 oflag=append conv=notrunc >/dev/null 2>&1
		i=$(($i+1))
	done
}

btrfs fil usage $MNT
do_falloc&
falloc_proc=$!
do_oappend&
oappend_proc=$!
sleep $TIME
kill $falloc_proc
kill $oappend_proc
ls -l $DIR
btrfs fil usage $MNT
