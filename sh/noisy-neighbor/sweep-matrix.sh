#!/bin/bash
# Matrix sweep: nr-villains x working-set on baseline kernel.
# One-time mkfs + file creation, then just remount between runs.
set -uo pipefail

DEV=/dev/vda
MNT=/mnt
DURATION=60
NR_VICTIM_JOBS=16

echo -1000 > /proc/$$/oom_score_adj

# One-time setup
if ! mount -o noatime,commit=1 $DEV $MNT 2>/dev/null; then
    echo "=== SETUP: mkfs ==="
    mkfs.btrfs -f -m single -d single $DEV >/dev/null
    mount -o noatime,commit=1 $DEV $MNT
fi
if [ ! -f $MNT/bigfile.1 ]; then
    echo "=== SETUP: creating 8 x 4GB files ==="
    mkdir -p $MNT/victims
    for i in $(seq 8); do
        echo "  bigfile.$i..."
        dd if=/dev/zero of=$MNT/bigfile.$i bs=1M count=4096 status=progress
    done
    sync
fi
umount $MNT

cd /home/borisb/local/scripts/sh/noisy-neighbor

for vjobs_per in 256 512; do
    villains=$((vjobs_per * 8))
    for ws_gb in 2 8 32; do
        per_file_sz=$((ws_gb << 30))
        per_file_sz=$((per_file_sz / 8))

        echo "============================================="
        echo "=== villains=$villains ws=${ws_gb}G ==="
        echo "============================================="

        # Fresh mount resets commit_stats
        mount -o noatime,commit=1 $DEV $MNT

        bpftrace runnable_lock_monitor.bt > /tmp/monitor.log 2>&1 &
        BT_PID=$!

        # Start villains
        for i in $(seq 8); do
            fio --filename=$MNT/bigfile.$i \
                --ioengine=psync --direct=0 --bs=1M --rw=randread \
                --numjobs=$vjobs_per --size=$per_file_sz \
                --time_based --runtime=$DURATION \
                --group_reporting --name=villain-$i \
                --output=/dev/null &
        done

        # Start victims
        mkdir -p $MNT/victims
        fio --directory=$MNT/victims \
            --ioengine=psync --direct=0 --bs=4k --rw=randwrite \
            --numjobs=$NR_VICTIM_JOBS --filesize=64k --nrfiles=8 \
            --time_based --runtime=$DURATION \
            --group_reporting --name=victim \
            --output=/dev/null &

        # Poll metrics
        prev_scan=0
        for t in $(seq 5 5 $DURATION); do
            sleep 5
            scan=$(awk '/pgscan_direct /{print $2}' /proc/vmstat)
            d_scan=$((scan - prev_scan))
            prev_scan=$scan
            free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
            cpu_psi=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | sed 's/avg10=//')
            mem_psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
            run=$(awk '/procs_running/{print $2}' /proc/stat)
            clast=$(awk '/last_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
            cmax=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
            echo "POLL t=$t: cpu=$cpu_psi mem=$mem_psi pgscan=+$d_scan free=${free}MB run=$run clast=${clast}ms cmax=${cmax}ms"
        done

        # Stop everything
        pkill -f fio 2>/dev/null
        kill $BT_PID 2>/dev/null
        sleep 2

        umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null

        # Extract results
        total_rl=$(grep -c 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null || echo 0)
        total_w=$(grep -c 'WAITERS' /tmp/monitor.log 2>/dev/null || echo 0)
        max_rn=$(grep 'RUNNABLE_LOCK' /tmp/monitor.log 2>/dev/null | \
            grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)
        max_wrn=$(grep 'WAITERS' /tmp/monitor.log 2>/dev/null | \
            grep -oP 'max_runnable=\K[0-9]+' | sort -n | tail -1)

        echo ""
        echo "RESULT: v=$villains ws=${ws_gb}G rl=$total_rl w=$total_w max_rn=${max_rn:-0}us max_wrn=${max_wrn:-0}us cmax=${cmax}ms cpu=${cpu_psi}% mem=${mem_psi}% run=$run"
        echo ""
    done
done
