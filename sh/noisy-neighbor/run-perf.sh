#!/bin/bash
cd /home/borisb/local/scripts/sh/noisy-neighbor

# Start the workload (120s to give perf time after ramp-up)
MKFS=1 bash standalone-minimal.sh /dev/vda /mnt 120 &
WORK_PID=$!

# Wait for pressure to build — file creation + ramp-up
sleep 90

# Sample CPU profile for 10 seconds — use fp call graph (lightweight)
echo "=== perf: sampling CPU for 10s ==="
perf record -a -g --call-graph fp -F 997 -o /tmp/perf.data -- sleep 10

echo ""
echo "=== perf report: top kernel functions ==="
perf report -i /tmp/perf.data --stdio --no-children -g none --sort sym --percent-limit 0.5 2>&1 | head -50

echo ""
echo "=== perf report: reclaim-related functions ==="
perf report -i /tmp/perf.data --stdio --no-children -g none --sort sym 2>&1 | grep -iE 'shrink|reclaim|lru|try_to_free|pgscan|kswapd|scan_folio|evict|isolat' | head -20

wait $WORK_PID 2>/dev/null
