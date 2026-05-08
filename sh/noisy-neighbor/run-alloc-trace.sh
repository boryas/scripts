#!/bin/bash
# Run the lock allocation trace at 2048/32G/8G for 30s.
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=50
VJOBS_PER=256
WS_GB=32
PER_FILE_SZ=$(( (WS_GB << 30) / 8 ))

echo -1000 > /proc/$$/oom_score_adj

if ! mount -o noatime,commit=1 $DEV $MNT 2>/dev/null; then
    mkfs.btrfs -f -m single -d single $DEV >/dev/null
    mount -o noatime,commit=1 $DEV $MNT
    mkdir -p $MNT/victims
    for i in $(seq 8); do
        dd if=/dev/zero of=$MNT/bigfile.$i bs=1M count=4096 status=progress
    done
    sync
fi
umount $MNT

cd /home/borisb/local/scripts/sh/noisy-neighbor

echo "=== ALLOC TRACE: 2048/32G ==="
mount -o noatime,commit=1 $DEV $MNT

# Start bpftrace FIRST (before workload, to avoid OOM)
bpftrace lock_alloc_trace.bt > /home/borisb/local/scripts/sh/noisy-neighbor/alloc-trace.out 2>&1 &
BT_PID=$!
echo -1000 > /proc/$BT_PID/oom_score_adj 2>/dev/null
sleep 3

for i in $(seq 8); do
    fio --filename=$MNT/bigfile.$i \
        --ioengine=psync --direct=0 --bs=1M --rw=randread \
        --numjobs=$VJOBS_PER --size=$PER_FILE_SZ \
        --time_based --runtime=$DURATION \
        --group_reporting --name=reader-$i \
        --output=/dev/null &
done

mkdir -p $MNT/victims
fio --directory=$MNT/victims \
    --ioengine=psync --direct=0 --bs=4k --rw=randwrite \
    --numjobs=16 --filesize=64k --nrfiles=8 \
    --time_based --runtime=$DURATION \
    --group_reporting --name=victim \
    --output=/dev/null &

sleep $DURATION
kill -INT $BT_PID 2>/dev/null
sleep 10

pkill -f fio 2>/dev/null
sleep 2
umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

echo "=== OUTPUT ==="
grep -v 'WARNING\|Return value\|delete(\|SmcTiers\|RetryingSender\|ProducerWrite\|scribe_cat\|ODSBatch\|Reading tiers\|^E0\|^I0\|^W0' \
    /home/borisb/local/scripts/sh/noisy-neighbor/alloc-trace.out
