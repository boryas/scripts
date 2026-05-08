#!/bin/bash
cd /home/borisb/local/scripts/sh/noisy-neighbor
bash reclaim-worker.sh 10 15 32M &
RW_PID=$!
MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 90 &
WORK_PID=$!
sleep 60
perf record -a -g --call-graph fp -F 997 -o /tmp/perf.data -- sleep 10
perf report -i /tmp/perf.data --stdio --no-children -g none --sort sym --percent-limit 0.3 2>&1 > /home/borisb/local/scripts/sh/noisy-neighbor/perf-fix-v3.txt
wait $WORK_PID
kill $RW_PID 2>/dev/null
