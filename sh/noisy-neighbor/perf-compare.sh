#!/bin/bash
# Capture perf profiles for 2G/2048 vs 32G/2048 readers.
# Runs each config once with perf record -ag for 45s mid-workload.
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16
VJOBS_PER=256
VILLAINS=$((VJOBS_PER * 8))

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

for ws_gb in 2 32; do
    per_file_sz=$(( (ws_gb << 30) / 8 ))

    echo "============================================="
    echo "=== PERF: v=$VILLAINS ws=${ws_gb}G ==="
    echo "============================================="

    mount -o noatime,commit=1 $DEV $MNT

    # Start readers
    for i in $(seq 8); do
        fio --filename=$MNT/bigfile.$i \
            --ioengine=psync --direct=0 --bs=1M --rw=randread \
            --numjobs=$VJOBS_PER --size=$per_file_sz \
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

    # Let workload stabilize 10s, then perf record for 40s
    sleep 10
    echo "  perf record starting (40s)..."
    perf record -ag -F 99 -o /tmp/perf-${ws_gb}g.data -- sleep 40 &
    PERF_PID=$!

    # Poll while perf runs
    for t in $(seq 15 5 $DURATION); do
        sleep 5
        free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
        mem_psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
        scan=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
        echo "  POLL t=$t: free=${free}MB mem=$mem_psi pgscan_d=$scan"
    done

    wait $PERF_PID 2>/dev/null
    pkill -f fio 2>/dev/null
    sleep 2

    umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

    # Generate report
    echo ""
    echo "=== PERF REPORT: ${ws_gb}G ==="
    perf report -i /tmp/perf-${ws_gb}g.data --stdio --no-children -g none \
        --percent-limit 0.5 2>/dev/null | head -80
    echo ""
done
