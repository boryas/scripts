#!/usr/bin/env bash

dev=/dev/tst/lol
mnt=/mnt/lol

run=$1
NOISE=$((100 << 20))
FILES=100
LOOPS=100

clean_data() {
	if [ $# -lt 1 ]; then
		echo "can't clean without data dir"
		return
	fi

	local dir=$1
	find $dir -name "*out" | xargs rm -f
	find $dir -name "*dat" | xargs rm -f
}

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
	local run=$1

	umount $mnt
	mkfs.btrfs -f $dev >/dev/null 2>&1
	mount $dev $mnt
	config-$run
}

rm_one() {
	local file=$(find $mnt -type f | shuf -n 1)
	[ -z $file ] || rm $file
}

rm_x() {
	local x=$1
	find $mnt -type f | shuf -n $x | xargs rm
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
	local dir=$1
	local size=$(btrfs fi usage --raw $mnt | grep size | awk '{print $3}')
	local unalloc=$(btrfs fi usage --raw $mnt | grep unallocated | awk '{print $3}')
	local alloc=$(btrfs fi usage --raw $mnt | grep Data,single | awk '{print $2}' | sed 's/Size:\(.*\),/\1/')
	local used=$(btrfs fi usage --raw $mnt | grep Data,single | awk '{print $3}' | sed 's/Used:\(.*\)/\1/')
	local unused=$(($alloc - $used))
	local reclaims=$(cat /sys/fs/btrfs/$(get_uuid)/allocation/data/reclaim_count) 
	local thresh=$(cat /sys/fs/btrfs/$(get_uuid)/allocation/data/bg_reclaim_threshold)

	pct $alloc $size >> $dir/alloc_pct.dat
	pct $used $alloc >> $dir/used_pct.dat
	pct $unused $unalloc >> $dir/unused_unalloc_ratio.dat
	echo $unalloc >> $dir/unalloc_bytes.dat
	echo $unused >> $dir/unused_bytes.dat
	echo $used >> $dir/used_bytes.dat
	echo $alloc >> $dir/alloc_bytes.dat
	echo $reclaims >> $dir/reclaims.dat
	echo $thresh >> $dir/thresh.dat
}

collect_loop() {
	local dir=results/$workload/$run
	mkdir -p $dir
	clean_data $dir

	while true
	do
		collect_data $dir
		sleep 5
	done

	btrfs filesystem usage $mnt > $dir/final_usage.out
}

do_fio() {
	local name=$1
	local size=$2
	local files=$3

	fio --name $name --directory $mnt --size=$size --nrfiles=$files --rw=write --ioengine=falloc >/dev/null 2>&1
}

frag_fio() {
	local iter=$1
	local size=$2
	local rm_pct=$3

	do_fio "frag.$iter" "$size" 100
	sync
	rm_x $rm_pct
	sync
}

bounce() {
	if [ $# -lt 2 ]; then
		echo "usage: bounce <level> <iters>"
		return 22
	fi
	local level=$1
	local iters=$2
	local level_bytes=$(numfmt --from=iec $level)
	local slop=$(($level_bytes / 10))
	local levelGiB=$(($level_bytes >> 30))

	level=$(($level_bytes - (1 << 30)))
	do_fio "bounce.$levelGiB" "$level" 100
	for i in $(seq $iters)
	do
		do_fio "slop.$i" $slop 10
		sync
		rm_x 10
		sync
		sleep 5
	done

	trigger_cleaner
	wait_reclaim_done
}

last_gig() {
	local SIZES=( $(get_frag_sizes | sort -n) )
	local i=0
	for sz in ${SIZES[@]}
	do
		frag_fio $i $sz 50
		i=$(($i + 1))
		sleep 1
	done
	trigger_cleaner
	wait_reclaim_done
}

strict_frag() {
	local level_pct=$1
	local pct_rm=$((100-$level_pct))
	local step=$((100 / $pct_rm))
	do_fio "strict_frag" "$(fs_size)" 100
	sync

	for i in $(seq 0 $(($pct_rm - 1)))
	do
		f=$mnt/strict_frag.0.$(($i * $step))
		rm $f
	done
	trigger_cleaner
	wait_reclaim_done
}

do_run() {
	local run=$1
	local workload=$2
	shift
	shift
	echo "$run $workload $@"

	setup $run
	dump_config

	collect_loop &
	local collect_pid=$!

	$workload $@

	kill $collect_pid
}

fs_size() {
	findmnt -n -b -o SIZE $mnt
}

get_frag_sizes() {
	# leave a few gigs for possibly over-relocating in
	#local total=$(((2 * $(fs_size)) - (2 << 30)))
	local total=$((2 * (100 << 30)))
	local per=$(($total / $LOOPS))
	for i in $(seq $LOOPS)
	do
		local noise=$(shuf -i 0-$NOISE -n 1)
		noise=$(($noise - ($NOISE / 2)))
		echo "$(($per + $noise))"
	done
}

#RUNS=("free-30" "free-50" "free-70" "per-50" "per-70" "free-dyn" "per-dyn")
RUNS=("free-30" "per-30" "per-dyn")

if [ $# -lt 1 ]
then
	echo "usage: frag.sh <workload> [args]"
	echo "workloads:"
	echo "	bounce <level (GiB)>"
	echo "	strict_frag <level (%)>"
	echo "	last_gig"
	exit 22
fi

workload=$1
shift

for run in ${RUNS[@]}
do
	do_run $run $workload $@
done

chown -R $SUDO_USER:$SUDO_USER results
