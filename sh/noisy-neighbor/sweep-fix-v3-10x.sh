#!/bin/bash
# 10x runs of v2/v3 fix kernel with userspace reclaim workers.
# Parameterized by ws_gb and vjobs_per.
# Usage: $0 <ws_gb> <vjobs_per> [nruns]
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16
WS_GB=${1:?Usage: $0 <ws_gb> <vjobs_per> [nruns]}
VJOBS_PER=${2:?Usage: $0 <ws_gb> <vjobs_per> [nruns]}
NRUNS=${3:-10}

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
    echo "=== FIX-V3 v=$VILLAINS ws=${WS_GB}G run=$run/$NRUNS ==="
    echo "============================================="

    mount -o noatime,commit=1 $DEV $MNT

    scan_before=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)

    # Start reclaim workers
    bash reclaim-worker.sh 10 15 32M &
    RW_PID=$!

    bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
    BT_PID=$!

    # Start readers
    for i in $(seq 8); do
        fio --filename=$MNT/bigfile.$i \
            --ioengine=psync --direct=0 --bs=1M --rw=randread \
            --numjobs=$VJOBS_PER --size=$PER_FILE_SZ \
            --time_based --runtime=$DURATION \
            --group_reporting --name=reader-$i \
            --output=/dev/null &
    done

    # Start victim writers
    mkdir -p $MNT/victims
    fio --directory=$MNT/victims \
        --ioengine=psync --direct=0 --bs=4k --rw=randwrite \
        --numjobs=$NR_VICTIM_JOBS --filesize=64k --nrfiles=8 \
        --time_based --runtime=$DURATION \
        --group_reporting --name=victim \
        --output=/dev/null &

    # Poll
    for t in $(seq 5 5 $DURATION); do
        sleep 5
        scan_now=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
        d_scan=$((scan_now - scan_before))
        free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
        cpu_psi=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | sed 's/avg10=//')
        mem_psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
        cmax=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
        echo "POLL t=$t: cpu=$cpu_psi mem=$mem_psi pgscan_d=+$d_scan free=${free}MB cmax=${cmax}ms"
    done

    pkill -f fio 2>/dev/null
    kill $BT_PID $RW_PID 2>/dev/null
    sleep 2

    scan_after=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
    total_pgscan=$((scan_after - scan_before))

    umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

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
    echo "RESULT: v=$VILLAINS ws=${WS_GB}G run=$run rl=$total_rl w=$total_w max_rn=${max_rn:-0}us max_wrn=${max_wrn:-0}us cmax=${cmax}ms total_rn_ms=${total_rn_us:-0} total_wrn_ms=${total_wrn_us:-0} pgscan_d=$total_pgscan"
    echo ""
done
