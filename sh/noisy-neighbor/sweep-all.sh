#!/bin/bash
# Combined sweep: villain and victim scaling with time_based fio.
# Run at 4G RAM.
cd /home/borisb/local/scripts/sh/noisy-neighbor

run_one() {
	local vjobs=$1 victims=$2
	local total_villains=$((vjobs * 4))

	echo "============================================="
	echo "=== villains=$total_villains victims=$victims ==="
	echo "============================================="

	sed -i "s/^FIO_JOBS_PER=.*/FIO_JOBS_PER=$vjobs/" standalone-minimal.sh
	sed -i "s/^NR_VICTIM_JOBS=.*/NR_VICTIM_JOBS=$victims/" standalone-minimal.sh

	bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
	BT_PID=$!
	sleep 2

	MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 60

	kill $BT_PID 2>/dev/null
	wait $BT_PID 2>/dev/null

	total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
	total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
	max_runnable=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
		grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
	max_waiters_runnable=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
		grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)

	echo ""
	echo "RESULT: villains=$total_villains victims=$victims runnable_lock=$total_rl waiters=$total_w max_runnable_us=${max_runnable:-0} max_waiters_runnable_us=${max_waiters_runnable:-0}"
	echo ""
}

# Villain sweep (victims=16)
for vjobs in 16 64 128 256 512; do
	run_one $vjobs 16
done

# Victim sweep (villains=1024)
for victims in 4 16 64 128 256 512; do
	run_one 256 $victims
done
