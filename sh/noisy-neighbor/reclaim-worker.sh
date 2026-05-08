#!/bin/bash
#
# Proactive userspace reclaim workers — simulates more parallel kswapd.
# Triggers on free memory dropping below a watermark, like kswapd does.
#
# Usage: reclaim-worker.sh [low_pct] [high_pct] [reclaim_bytes]
#   low_pct:  start reclaiming when MemFree drops below this % (default: 10)
#   high_pct: stop reclaiming when MemFree rises above this % (default: 15)
#   reclaim_bytes: amount per reclaim write (default: 32M)

LOW_PCT=${1:-10}
HIGH_PCT=${2:-15}
RECLAIM_BYTES=${3:-32M}
NR_WORKERS=${4:-$(nproc)}

NR_CPUS=$(nproc)
TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
LOW_KB=$((TOTAL_KB * LOW_PCT / 100))
HIGH_KB=$((TOTAL_KB * HIGH_PCT / 100))

echo "reclaim-worker: $NR_WORKERS workers, low=${LOW_PCT}% (${LOW_KB}KB) high=${HIGH_PCT}% (${HIGH_KB}KB), reclaim=${RECLAIM_BYTES}"

worker() {
    local cpu=$1
    taskset -c "$cpu" bash -c '
        while true; do
            free_kb=$(awk "/^MemFree:/{print \$2}" /proc/meminfo)
            if [ "$free_kb" -lt '"$LOW_KB"' ]; then
                while true; do
                    echo '"$RECLAIM_BYTES"' > /sys/fs/cgroup/memory.reclaim 2>/dev/null || true
                    free_kb=$(awk "/^MemFree:/{print \$2}" /proc/meminfo)
                    [ "$free_kb" -ge '"$HIGH_KB"' ] && break
                done
            fi
            sleep 0.01
        done
    '
}

PIDS=()
for i in $(seq 0 $((NR_WORKERS - 1))); do
    cpu=$((i % NR_CPUS))
    worker "$cpu" &
    PIDS+=($!)
done

trap "kill ${PIDS[*]} 2>/dev/null; wait; echo 'reclaim-worker: stopped'" EXIT
wait
