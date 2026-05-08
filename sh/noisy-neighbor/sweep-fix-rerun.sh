#!/bin/bash
# Rerun 1024v/32G and 2048v/32G with fix, 3x each.
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16

echo -1000 > /proc/$$/oom_score_adj

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

run_one() {
    local vjobs_per=$1 ws_gb=$2 run_num=$3
    local villains=$((vjobs_per * 8))
    local per_file_sz=$(( (ws_gb << 30) / 8 ))

    echo "============================================="
    echo "=== v=$villains ws=${ws_gb}G run=$run_num ==="
    echo "============================================="

    mount -o noatime,commit=1 $DEV $MNT

    bash reclaim-worker.sh 10 15 32M &
    RW_PID=$!

    bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
    BT_PID=$!

    for i in $(seq 8); do
        fio --filename=$MNT/bigfile.$i \
            --ioengine=psync --direct=0 --bs=1M --rw=randread \
            --numjobs=$vjobs_per --size=$per_file_sz \
            --time_based --runtime=$DURATION \
            --group_reporting --name=villain-$i \
            --output=/dev/null &
    done

    mkdir -p $MNT/victims
    fio --directory=$MNT/victims \
        --ioengine=psync --direct=0 --bs=4k --rw=randwrite \
        --numjobs=$NR_VICTIM_JOBS --filesize=64k --nrfiles=8 \
        --time_based --runtime=$DURATION \
        --group_reporting --name=victim \
        --output=/dev/null &

    prev_scan=0
    for t in $(seq 5 5 $DURATION); do
        sleep 5
        scan=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
        d_scan=$((scan - prev_scan))
        prev_scan=$scan
        free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
        cpu_psi=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | sed 's/avg10=//')
        mem_psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
        run_q=$(awk '/procs_running/{print $2}' /proc/stat)
        cmax=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
    done

    pkill -f fio 2>/dev/null
    kill $BT_PID $RW_PID 2>/dev/null
    sleep 2

    umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

    total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
    total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
    max_rn=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
        grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
    max_wrn=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
        grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)

    echo ""
    echo "RESULT: v=$villains ws=${ws_gb}G run=$run_num rl=$total_rl w=$total_w max_rn=${max_rn:-0}us max_wrn=${max_wrn:-0}us cmax=${cmax}ms"
    echo ""
}

for vjobs_per in 128 256; do
    for run in 1 2 3; do
        run_one $vjobs_per 32 $run
    done
done
