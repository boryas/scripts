#!/bin/bash
# Sweep worker count at 2048/32G/8G. 3 runs per worker count.
# Tests: 0, 2, 4, 8, 16 workers
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16
VJOBS_PER=256
VILLAINS=$((VJOBS_PER * 8))
WS_GB=32
PER_FILE_SZ=$(( (WS_GB << 30) / 8 ))
NRUNS=3

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

for nw in 0 2 4 8 16; do
    for run in $(seq 1 $NRUNS); do
        echo "============================================="
        echo "=== WORKERS=$nw v=$VILLAINS ws=${WS_GB}G run=$run/$NRUNS ==="
        echo "============================================="

        mount -o noatime,commit=1 $DEV $MNT

        scan_before=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)

        # Start reclaim workers (0 = none)
        RW_PID=""
        if [ "$nw" -gt 0 ]; then
            bash reclaim-worker.sh 10 15 32M $nw &
            RW_PID=$!
        fi

        bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
        BT_PID=$!

        for i in $(seq 8); do
            fio --filename=$MNT/bigfile.$i \
                --ioengine=psync --direct=0 --bs=1M --rw=randread \
                --numjobs=$VJOBS_PER --size=$PER_FILE_SZ \
                --time_based --runtime=$DURATION \
                --group_reporting --name=reader-$i \
                --output=/tmp/fio-reader-$i.out &
        done

        mkdir -p $MNT/victims
        fio --directory=$MNT/victims \
            --ioengine=psync --direct=0 --bs=4k --rw=randwrite \
            --numjobs=$NR_VICTIM_JOBS --filesize=64k --nrfiles=8 \
            --time_based --runtime=$DURATION \
            --group_reporting --name=victim \
            --output=/tmp/fio-victim.out &

        for t in $(seq 5 5 $DURATION); do
            sleep 5
            cmax=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
        done

        pkill -f fio 2>/dev/null
        kill $BT_PID 2>/dev/null
        [ -n "$RW_PID" ] && kill $RW_PID 2>/dev/null
        sleep 2

        scan_after=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
        total_pgscan=$((scan_after - scan_before))

        read_bw_all=$(grep -h 'READ:' /tmp/fio-reader-*.out 2>/dev/null | \
            grep -oP 'bw=\K[0-9.]+' | awk '{s+=$1}END{printf "%.0f", s}')
        write_bw=$(grep -h 'WRITE:' /tmp/fio-victim.out 2>/dev/null | \
            grep -oP 'bw=\K[0-9.]+[A-Za-z/]+' | head -1)

        umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

        total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
        total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
        max_wrn=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
            grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
        total_rn_us=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
            grep -oP 'runnable=\K[0-9]+' | awk '{s+=$1}END{print int(s/1000)}')
        total_wrn_us=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
            grep -oP 'runnable=\K[0-9]+' | awk '{s+=$1}END{print int(s/1000)}')

        echo ""
        echo "RESULT: workers=$nw run=$run rl=$total_rl w=$total_w max_wrn=${max_wrn:-0}us cmax=${cmax}ms total_rn_ms=${total_rn_us:-0} total_wrn_ms=${total_wrn_us:-0} pgscan_d=$total_pgscan read_bw=${read_bw_all:-0} write_bw=${write_bw:-0}"
        echo ""
    done
done
