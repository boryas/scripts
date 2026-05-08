#!/bin/bash
cd /home/borisb/local/scripts/sh/noisy-neighbor

bpftrace /home/borisb/local/scripts/sh/noisy-neighbor/runnable_lock_monitor.bt \
	> /tmp/monitor.log 2>&1 &
BT_PID=$!
sleep 1

MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 60

kill $BT_PID 2>/dev/null
wait $BT_PID 2>/dev/null
echo ""
echo "=== BPFTRACE RESULTS ==="
grep -v '^[EIW]0' /tmp/monitor.log | grep -v 'WARNING:' | grep -v 'SmcTiers\|ProducerWrite'
