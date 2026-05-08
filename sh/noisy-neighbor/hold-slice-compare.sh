#!/bin/bash
# Run hold_and_slice.bt for 2G/2048 and 32G/2048, compare histograms.
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=45
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
    echo "=== HOLD+SLICE: v=$VILLAINS ws=${ws_gb}G ==="
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

    # Let workload stabilize, then trace for 30s
    sleep 10
    echo "  bpftrace starting (30s)..."
    bpftrace hold_and_slice.bt > /home/borisb/local/scripts/sh/noisy-neighbor/hold-slice-${ws_gb}g.out 2>&1 &
    BT_PID=$!
    sleep 30
    kill -INT $BT_PID 2>/dev/null
    sleep 5
    echo "  bpftrace output:"
    grep -v 'WARNING\|Return value\|delete(' /home/borisb/local/scripts/sh/noisy-neighbor/hold-slice-${ws_gb}g.out

    pkill -f fio 2>/dev/null
    sleep 2
    umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

    echo ""
done
