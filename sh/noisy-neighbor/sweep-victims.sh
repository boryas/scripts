#!/bin/bash
# Sweep victim writer count and collect key metrics from each run.
cd /home/borisb/local/scripts/sh/noisy-neighbor

for nv in 4 16 64 128 256 512; do
	echo "============================================="
	echo "=== SWEEP: NR_VICTIM_JOBS=$nv ==="
	echo "============================================="

	# Patch the victim count
	sed -i "s/^NR_VICTIM_JOBS=.*/NR_VICTIM_JOBS=$nv/" standalone-minimal.sh

	# Run bpftrace sidecar
	bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
	BT_PID=$!
	sleep 2

	# Run the workload (skip mkfs, reuse existing files)
	bash standalone-minimal.sh /dev/vda /mnt 60

	# Stop bpftrace
	kill $BT_PID 2>/dev/null
	wait $BT_PID 2>/dev/null

	# Extract key metrics
	total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
	total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
	max_runnable=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
		grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
	max_waiters_runnable=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
		grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)

	echo ""
	echo "RESULT: victims=$nv runnable_lock=$total_rl waiters=$total_w max_runnable_us=${max_runnable:-0} max_waiters_runnable_us=${max_waiters_runnable:-0}"
	echo ""
done
