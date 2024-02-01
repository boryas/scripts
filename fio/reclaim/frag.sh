#!/usr/bin/env bash

dev=/dev/tst/lol
mnt=/mnt/lol

run=$1
SZ=$((100 << 30))
NOISE=$((100 << 20))
FILES=100
LOOPS=100

config-free() {
	local sysfs=/sys/fs/btrfs/$(get_uuid)
	local si=$sysfs/allocation/data
	echo $1 > $si/bg_reclaim_threshold
}

config-free-0() {
	config-free 0
}
config-free-30() {
	config-free 30
}
config-free-50() {
	config-free 50
}
config-free-70() {
	config-free 70
}

config-per() {
	local sysfs=/sys/fs/btrfs/$(get_uuid)
	local si=$sysfs/allocation/data
	echo $1 > $si/bg_reclaim_threshold
	echo 1 > $si/periodic_reclaim
}
config-per-30() {
	config-per 30
}
config-per-50() {
	config-per 50
}
config-per-70() {
	config-per 70
}

config-free-dyn() {
	local sysfs=/sys/fs/btrfs/$(get_uuid)
	local si=$sysfs/allocation/data
	echo 1 > $si/dynamic_reclaim
}
config-per-dyn() {
	local sysfs=/sys/fs/btrfs/$(get_uuid)
	local si=$sysfs/allocation/data
	echo 1 > $si/dynamic_reclaim
	echo 1 > $si/periodic_reclaim
}

dump_config() {
	local sysfs=/sys/fs/btrfs/$(get_uuid)
	local si=$sysfs/allocation/data
	echo "$run config"
	echo "thresh: $(cat $si/bg_reclaim_threshold)"
	echo "dyn: $(cat $si/dynamic_reclaim)"
	echo "per: $(cat $si/periodic_reclaim)"
}

setup() {
	mkdir -p $run
	umount $mnt
	mkfs.btrfs -f $dev >/dev/null 2>&1
	mount $dev $mnt
	config-$run
}

rm_one() {
	local file=$(find $mnt -type f -name '[AB]*' | shuf -n 1)
	[ -z $file ] || rm $file
}

rm_loop() {
	local count=$1
	local i=0

	while [ $i -lt $count ]
	do
		rm_one
		i=$(($i+1))
	done
}

get_uuid() {
	findmnt -n -o UUID $mnt
}

trigger_cleaner() {
	btrfs filesystem sync $mnt
	sleep 1
	btrfs filesystem sync $mnt
}

wait_reclaim_done() {
	# TODO: loop reading unalloc?
	sleep 30
}

pct() {
	local dividend=$1
	local divisor=$2
	echo "100 * $dividend / $divisor" | bc
}

collect_data() {
	size=$(btrfs fi usage --raw $mnt | grep size | awk '{print $3}')
	unalloc=$(btrfs fi usage --raw $mnt | grep unallocated | awk '{print $3}')
	alloc=$(btrfs fi usage --raw $mnt | grep Data,single | awk '{print $2}' | sed 's/Size:\(.*\),/\1/')
	used=$(btrfs fi usage --raw $mnt | grep Data,single | awk '{print $3}' | sed 's/Used:\(.*\)/\1/')
	unused=$(($alloc - $used))
	relocs=$(cat /sys/fs/btrfs/$(get_uuid)/allocation/data/relocation_count) 
	thresh=$(cat /sys/fs/btrfs/$(get_uuid)/allocation/data/bg_reclaim_threshold)
	pct $alloc $size >> $run/alloc_pct.dat
	pct $used $alloc >> $run/used_pct.dat
	pct $unused $unalloc >> $run/unused_unalloc_ratio.dat
	echo $unalloc >> $run/unalloc_bytes.dat
	echo $unused >> $run/unused_bytes.dat
	echo $used >> $run/used_bytes.dat
	echo $alloc >> $run/alloc_bytes.dat
	echo $relocs >> $run/relocs.dat
	echo $thresh >> $run/thresh.dat
}

collect_loop() {
	while true
	do
		collect_data
		sleep 5
	done
}

one_pass() {
	local iter=$1
	local size=$2

	fio --name A.$iter --directory $mnt --size=$size --nrfiles=100 --rw=write --ioengine=falloc >/dev/null 2>&1
	rm_loop 50
	sync
	#trigger_cleaner
}

filler() {
	local size=$1
	local name=$2
	fio --name $name --directory $mnt --size=$size --nrfiles=100 --rw=write --ioengine=falloc >/dev/null 2>&1
	sync
}

do_run() {
	local run=$1
	setup
	dump_config

	collect_loop &
	local collect_pid=$!

	local i=0
	for sz in ${SIZES[@]};
	do
		#echo "run $run pass $i sz $sz"
		one_pass $i $sz
		i=$(($i + 1))
	done

	trigger_cleaner
	wait_reclaim_done
	kill $collect_pid
	btrfs filesystem usage $mnt > $run/final_usage.out
}

get_sizes() {
	local per=$((2 * $SZ / $LOOPS))
	for i in $(seq $LOOPS)
	do
		local noise=$(shuf -i 0-$NOISE -n 1)
		noise=$(($noise - ($NOISE / 2)))
		echo "$(($per + $noise))"
	done
}

SIZES=( $(get_sizes) )

RUNS=("free-30" "free-50" "free-70" "per-50" "per-70" "free-dyn" "per-dyn")

find . -name "*dat" | xargs rm
for run in ${RUNS[@]}
do
	do_run $run
done
