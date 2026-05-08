#!/bin/bash
# 10x runs of unpatched kernel. Villains parameterized by $1.
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16
VJOBS_PER=${1:?Usage: $0 <vjobs_per>}

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

ws_gb=32
per_file_sz=$(( (ws_gb << 30) / 8 ))
villains=$((VJOBS_PER * 8))

for run in $(seq 1 10); do
    echo "============================================="
    echo "=== UNPATCHED v=$villains ws=${ws_gb}G run=$run ==="
    echo "============================================="

    mount -o noatime,commit=1 $DEV $MNT

    bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
    BT_PID=$!

    for i in $(seq 8); do
        fio --filename=$MNT/bigfile.$i \
            --ioengine=psync --direct=0 --bs=1M --rw=randread \
            --numjobs=$VJOBS_PER --size=$per_file_sz \
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
        cmax=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
    done

    pkill -f fio 2>/dev/null
    kill $BT_PID 2>/dev/null
    sleep 2

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
    echo "RESULT: v=$villains ws=${ws_gb}G run=$run rl=$total_rl w=$total_w max_rn=${max_rn:-0}us max_wrn=${max_wrn:-0}us cmax=${cmax}ms total_rn_ms=${total_rn_us:-0} total_wrn_ms=${total_wrn_us:-0}"
    echo ""
done
