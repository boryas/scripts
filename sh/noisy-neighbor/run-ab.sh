#!/bin/bash
# A/B test: run the reproducer with and without proactive reclaim workers.
cd /home/borisb/local/scripts/sh/noisy-neighbor

extract_results() {
    local log=$1
    local total_rl=$(grep -c 'RUNNABLE_LOCK' "$log" 2>/dev/null || echo 0)
    local total_w=$(grep -c 'WAITERS' "$log" 2>/dev/null || echo 0)
    local max_rn=$(grep 'RUNNABLE_LOCK' "$log" 2>/dev/null | \
        grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
    local max_wrn=$(grep 'WAITERS' "$log" 2>/dev/null | \
        grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
    local cpu_psi=$(grep 'POLL:' "$log" | tail -1 | grep -oP 'cpu_psi=\K[0-9.]+')
    local mem_psi=$(grep 'POLL:' "$log" | tail -1 | grep -oP 'mem_psi=\K[0-9.]+')
    echo "  RUNNABLE_LOCK=$total_rl  WAITERS=$total_w  max_runnable=${max_rn:-0}us  max_waiters_runnable=${max_wrn:-0}us  cpu_psi=${cpu_psi}%  mem_psi=${mem_psi}%"
}

run_one() {
    bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
    BT_PID=$!
    sleep 2

    MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 60

    kill $BT_PID 2>/dev/null
    wait $BT_PID 2>/dev/null
}

echo "============================================="
echo "=== A: BASELINE (no proactive reclaim) ==="
echo "============================================="
run_one
cp /tmp/monitor.log /tmp/monitor-baseline.log
echo ""
echo "BASELINE:"
extract_results /tmp/monitor-baseline.log
echo ""

echo "============================================="
echo "=== B: WITH PROACTIVE RECLAIM WORKERS ==="
echo "============================================="
bash reclaim-worker.sh 70 64M &
RW_PID=$!
sleep 2

run_one
kill $RW_PID 2>/dev/null
wait $RW_PID 2>/dev/null
cp /tmp/monitor.log /tmp/monitor-reclaim.log
echo ""
echo "WITH RECLAIM WORKERS:"
extract_results /tmp/monitor-reclaim.log
echo ""

echo "============================================="
echo "=== COMPARISON ==="
echo "============================================="
echo "BASELINE:"
extract_results /tmp/monitor-baseline.log
echo "WITH RECLAIM WORKERS:"
extract_results /tmp/monitor-reclaim.log
