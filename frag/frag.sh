#!/bin/sh

# generate fragmentation in btrfs with fallocate and small buffered writes

DEV=$1
MNT=$2
TIME=$3

DIR=$MNT/enospc
# 64k writes
BUF_WRITE_SZ="64K"
# 64k * 2k = 128M per file
BUF_WRITE_NR=$((2 * 1024))
# 32 * 128M = 4G total
NR_LOGGERS=32

# 1G fallocs
FALLOC_SIZE="1G"
# 4 * 1G = 4G total
NR_FALLOCERS=4
# 100 ms between falloc/delete
FALLOC_PAUSE_MAX="100"

do_falloc() {
	local i=0
	while (true)
	do
		local slot=$(($i % $NR_FALLOC_FILES))
		local f=$DIR/falloc-$slot
		fallocate -l1G $f
		if [ $(($i % 100)) -eq 0 ]
		then
			local del_slot=$(( ($i / 100) % $NR_FALLOC_FILES ))
			#echo "FALLOC-DEL $i $del_slot"
			rm $DIR/falloc-$del_slot
		fi
		i=$(($i+1))
	done
}

random_sleep() {
	local r=$(dd if=/dev/urandom bs=1 count=1 2>/dev/null | od -t u1 | head -1 | awk '{print $2}')
	local t=$((r / 255))
	sleep $t
}

do_falloc2() {
	local n=$1
	local f=$DIR/falloc-$n
	local i=0
	while (true)
	do
		fallocate -l$FALLOC_SIZE $f
		random_sleep
		rm $f
	done
}

do_overwrite() {
	local n=$1
	local log=$DIR/log-$n
	local i=0
	while (true)
	do
		dd if=/dev/zero of=$log bs=$BUF_WRITE_SZ count=1 conv=notrunc,fdatasync seek=$i >/dev/null 2>&1
		i=$(($i+1))
		if [ $((i % $BUF_WRITE_NR)) -eq 0 ]
		then
			echo "LOOPED $n"
			i=0
		fi
	done
}

worker() {
	local work=$@
	$work &
	proc=$!
	sleep $TIME
	kill $proc
}

# let the fs reclaim empty data BGs
finish() {
	echo "done. sync and sleep 30 to reclaim empty block groups"
	rm $DIR/falloc*
	sync
	sleep 30
}

btrfs fil usage $MNT
for i in $(seq $NR_FALLOCERS); do
	worker do_falloc2 $i &
done
for i in $(seq $NR_LOGGERS); do
	worker do_overwrite $i &
done
echo "workers started. sleep $TIME"
sleep $TIME
finish
ls -lh $DIR
btrfs fil usage $MNT
