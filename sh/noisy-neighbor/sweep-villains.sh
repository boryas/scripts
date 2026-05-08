#!/bin/bash
# Sweep villain reader count (via FIO_JOBS_PER) with victims fixed at 16.
cd /home/borisb/local/scripts/sh/noisy-neighbor

for vjobs in 16 64 128 256 512; do
	echo "============================================="
	echo "=== SWEEP: FIO_JOBS_PER=$vjobs (total=$((vjobs * 4))) ==="
	echo "============================================="

	sed -i "s/^FIO_JOBS_PER=.*/FIO_JOBS_PER=$vjobs/" standalone-minimal.sh

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
	echo "RESULT: villains=$((vjobs * 4)) runnable_lock=$total_rl waiters=$total_w max_runnable_us=${max_runnable:-0} max_waiters_runnable_us=${max_waiters_runnable:-0}"
	echo ""
done
