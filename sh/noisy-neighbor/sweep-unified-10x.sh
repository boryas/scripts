#!/bin/bash
# Unified 10x sweep script. Identical workload for baseline and fix.
# The only difference: fix runs reclaim workers.
#
# Usage: $0 <label> <ws_gb> <vjobs_per> [nruns] [--workers]
#   label:      tag for RESULT lines (e.g., "unpatched", "fix-v3")
#   ws_gb:      working set in GB
#   vjobs_per:  fio jobs per file (8 files, total readers = vjobs_per * 8)
#   nruns:      iterations (default 10)
#   --workers:  start userspace reclaim workers (16 per-CPU)
set -uo pipefail

LABEL=${1:?Usage: $0 <label> <ws_gb> <vjobs_per> [nruns] [--workers]}
WS_GB=${2:?}
VJOBS_PER=${3:?}
NRUNS=${4:-10}
USE_WORKERS=false
[ "${5:-}" = "--workers" ] && USE_WORKERS=true

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16
VILLAINS=$((VJOBS_PER * 8))
PER_FILE_SZ=$(( (WS_GB << 30) / 8 ))

echo -1000 > /proc/$$/oom_score_adj

# One-time setup
if ! mount -o noatime,commit=1 $DEV $MNT 2>/dev/null; then
    mkfs.btrfs -f -m single -d single $DEV >/dev/null
    mount -o noatime,commit=1 $DEV $MNT
    mkdir -p $MNT/victims
    for i in $(seq 8); do
        echo "creating bigfile.$i (4GB)..."
        dd if=/dev/zero of=$MNT/bigfile.$i bs=1M count=4096 status=progress
    done
    sync
fi
umount $MNT

cd /home/borisb/local/scripts/sh/noisy-neighbor

for run in $(seq 1 $NRUNS); do
    echo "============================================="
    echo "=== $LABEL v=$VILLAINS ws=${WS_GB}G run=$run/$NRUNS workers=$USE_WORKERS ==="
    echo "============================================="

    mount -o noatime,commit=1 $DEV $MNT

    scan_before=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
    free_before=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)

    # Optional reclaim workers
    RW_PID=""
    if $USE_WORKERS; then
        bash reclaim-worker.sh 10 15 32M &
        RW_PID=$!
    fi

    bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
    BT_PID=$!

    # Start readers — capture throughput
    for i in $(seq 8); do
        fio --filename=$MNT/bigfile.$i \
            --ioengine=psync --direct=0 --bs=1M --rw=randread \
            --numjobs=$VJOBS_PER --size=$PER_FILE_SZ \
            --time_based --runtime=$DURATION \
            --group_reporting --name=reader-$i \
            --output=/tmp/fio-reader-$i.out &
    done

    # Start victim writers — capture throughput
    mkdir -p $MNT/victims
    fio --directory=$MNT/victims \
        --ioengine=psync --direct=0 --bs=4k --rw=randwrite \
        --numjobs=$NR_VICTIM_JOBS --filesize=64k --nrfiles=8 \
        --time_based --runtime=$DURATION \
        --group_reporting --name=victim \
        --output=/tmp/fio-victim.out &

    # Poll every 5s
    for t in $(seq 5 5 $DURATION); do
        sleep 5
        scan_now=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
        d_scan=$((scan_now - scan_before))
        free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
        cpu_psi=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | sed 's/avg10=//')
        mem_psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
        run_q=$(awk '/procs_running/{print $2}' /proc/stat)
        blk=$(awk '/procs_blocked/{print $2}' /proc/stat)
        cmax=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
        echo "POLL t=$t: cpu=$cpu_psi mem=$mem_psi pgscan_d=+$d_scan free=${free}MB run=$run_q blk=$blk cmax=${cmax}ms"
    done

    # Stop
    pkill -f fio 2>/dev/null
    kill $BT_PID 2>/dev/null
    [ -n "$RW_PID" ] && kill $RW_PID 2>/dev/null
    sleep 2

    # Final snapshots
    scan_after=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
    total_pgscan=$((scan_after - scan_before))
    free_after=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    cpu_psi_final=$(awk '/^some/{print $4}' /proc/pressure/cpu 2>/dev/null | sed 's/avg300=//')
    mem_psi_final=$(awk '/^some/{print $4}' /proc/pressure/memory 2>/dev/null | sed 's/avg300=//')

    # Extract fio throughput (aggregate read BW across all reader instances)
    read_bw=$(grep -h 'READ:' /tmp/fio-reader-*.out 2>/dev/null | \
        grep -oP 'bw=\K[0-9.]+[A-Za-z/]+' | head -1)
    read_bw_all=$(grep -h 'READ:' /tmp/fio-reader-*.out 2>/dev/null | \
        grep -oP 'bw=\K[0-9.]+' | awk '{s+=$1}END{printf "%.0f", s}')
    write_bw=$(grep -h 'WRITE:' /tmp/fio-victim.out 2>/dev/null | \
        grep -oP 'bw=\K[0-9.]+[A-Za-z/]+' | head -1)

    umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

    # Extract lock monitor results
    total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
    total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
    max_rn=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
        grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
    max_wrn=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
        grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
    total_rn_us=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
        grep -oP 'runnable=\K[0-9]+' | awk '{s+=$1}END{print int(s/1000)}')
    total_wrn_us=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
        grep -oP 'runnable=\K[0-9]+' | awk '{s+=$1}END{print int(s/1000)}')

    echo ""
    echo "RESULT: label=$LABEL v=$VILLAINS ws=${WS_GB}G run=$run rl=$total_rl w=$total_w max_rn=${max_rn:-0}us max_wrn=${max_wrn:-0}us cmax=${cmax}ms total_rn_ms=${total_rn_us:-0} total_wrn_ms=${total_wrn_us:-0} pgscan_d=$total_pgscan free_before=${free_before}MB free_after=${free_after}MB cpu_psi=$cpu_psi_final mem_psi=$mem_psi_final read_bw=${read_bw_all:-0}MiB/s write_bw=${write_bw:-0}"
    echo ""
done
