#!/bin/bash
cd /home/borisb/local/scripts/sh/noisy-neighbor

bash reclaim-worker.sh 10 15 32M &
RW_PID=$!
sleep 2

bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
BT_PID=$!
sleep 2

MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 60

kill $BT_PID 2>/dev/null; wait $BT_PID 2>/dev/null
kill $RW_PID 2>/dev/null; wait $RW_PID 2>/dev/null

echo ""
echo "=== RESULTS ==="
total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
max_rn=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
max_wrn=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
echo "RUNNABLE_LOCK=$total_rl  WAITERS=$total_w  max_runnable=${max_rn:-0}us  max_waiters_runnable=${max_wrn:-0}us"
echo ""
echo "Top WAITERS:"
grep 'WAITERS' /tmp/monitor.log | sort -t= -k4 -n | tail -5
