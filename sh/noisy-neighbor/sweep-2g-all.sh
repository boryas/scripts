#!/bin/bash
# Full 2G baseline sweep: all villain counts, 10x each.
# Then run 32G/2048 10x for direct comparison with matched instrumentation.
set -uo pipefail

NRUNS=${1:-10}

echo "=== 2G SWEEP: 10x each at 64, 256, 512, 1024, 2048 readers ==="
echo "=== Then 32G/2048 10x for comparison ==="
echo "=== Total: 60 runs × ~65s ≈ ~65 min ==="
echo ""

cd /home/borisb/local/scripts/sh/noisy-neighbor

for vjobs_per in 8 32 64 128 256; do
    v=$((vjobs_per * 8))
    echo "########## Starting 2G / ${v} readers / ${NRUNS}x ##########"
    bash sweep-baseline-10x.sh 2 $vjobs_per $NRUNS
    echo ""
done

echo "########## Starting 32G / 2048 readers / ${NRUNS}x ##########"
bash sweep-baseline-10x.sh 32 256 $NRUNS
