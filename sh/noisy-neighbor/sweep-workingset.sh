#!/bin/bash
# Sweep working set size on baseline kernel.
# Fixed: 16 victims, no cpuset, 60s each.
# Variable: BIGFILE_SZ
cd /home/borisb/local/scripts/sh/noisy-neighbor

for ws_gb in 2 8 32; do
	echo "============================================="
	echo "=== WORKINGSET: ${ws_gb}G ==="
	echo "============================================="

	sed -i "s/^BIGFILE_SZ=.*/BIGFILE_SZ=\$((${ws_gb} << 30))/" standalone-minimal.sh

	bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
	BT_PID=$!
	sleep 2

	MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 60 2>&1 | tee /tmp/run.log

	kill $BT_PID 2>/dev/null
	wait $BT_PID 2>/dev/null

	total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
	total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
	max_rn=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
		grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
	max_wrn=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
		grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
	commit_max=$(grep 'POLL:' /tmp/run.log | grep -oP 'commit_max=\K[0-9]+' | sort -n | tail -1)
	cpu_psi=$(grep 'POLL:' /tmp/run.log | tail -1 | grep -oP 'cpu_psi=\K[0-9.]+')
	mem_psi=$(grep 'POLL:' /tmp/run.log | tail -1 | grep -oP 'mem_psi=\K[0-9.]+')
	pgscan_total=$(grep 'POLL:' /tmp/run.log | grep -oP 'pgscan_d=\+\K[0-9]+' | awk '{s+=$1}END{print s}')
	run_avg=$(grep 'POLL:' /tmp/run.log | grep -oP 'run=\K[0-9]+' | awk '{s+=$1;n++}END{if(n)print int(s/n);else print 0}')

	echo ""
	echo "RESULT: ws=${ws_gb}G rl=$total_rl w=$total_w max_rn=${max_rn:-0}us max_wrn=${max_wrn:-0}us commit_max=${commit_max:-0}ms cpu_psi=${cpu_psi}% mem_psi=${mem_psi}% pgscan=${pgscan_total} run_avg=${run_avg}"
	echo ""
done
