#!/usr/bin/env bash
#
# Run inside vng VM. Launches the reproducer with perf and bpftrace.
# Results persist to SCRIPT_DIR/results/ via --rwdir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$SCRIPT_DIR/results"
mkdir -p "$RESULTS"

DEV=/dev/vda
MNT=/tmp/test
DURATION=${1:-60}

mkdir -p "$MNT"

# Show scheduler timeslice
echo "=== sched_base_slice ==="
cat /proc/sys/kernel/sched_base_slice_ns 2>/dev/null || echo "(not available)"
echo "online CPUs: $(nproc)"

echo "=== Starting perf record -ag ==="
perf record -ag -o /tmp/perf.data -- sleep $((DURATION + 120)) &
PERF_PID=$!

echo "=== Starting bpftrace ==="
timeout $((DURATION + 90)) bpftrace "$SCRIPT_DIR/trace-shrinker.bt" \
	> "$RESULTS/bpftrace.log" 2>&1 &
BT_PID=$!
sleep 2

echo "=== Running reproducer for ${DURATION}s ==="
"$SCRIPT_DIR/standalone-minimal.sh" "$DEV" "$MNT" "$DURATION" 2>&1 | tee "$RESULTS/repro.log" || true

echo "=== Stopping tracing ==="
kill -INT "$PERF_PID" 2>/dev/null || true
kill -INT "$BT_PID" 2>/dev/null || true
wait "$PERF_PID" 2>/dev/null || true
wait "$BT_PID" 2>/dev/null || true

echo "=== Generating perf reports ==="
perf report -i /tmp/perf.data --stdio --no-children \
	-s comm,symbol --percent-limit 0.3 \
	> "$RESULTS/perf-report.txt" 2>&1

perf report -i /tmp/perf.data --stdio --no-children \
	-g fractal,5 --percent-limit 0.3 \
	> "$RESULTS/perf-full-stacks.txt" 2>&1 || true

# Extract contention-relevant stacks
{
	echo "=== find_first_inode_to_shrink stacks ==="
	grep -B2 -A25 'find_first_inode_to_shrink' "$RESULTS/perf-full-stacks.txt" 2>/dev/null || echo "(none)"
	echo ""
	echo "=== spinlock slowpath stacks ==="
	grep -B2 -A20 '__pv_queued_spin_lock_slowpath' "$RESULTS/perf-full-stacks.txt" 2>/dev/null | head -200 || echo "(none)"
} > "$RESULTS/contention-stacks.txt" 2>&1

echo ""
echo "=== bpftrace results (shrinker xa_lock hold times) ==="
cat "$RESULTS/bpftrace.log"
echo ""
echo "=== Top symbols ==="
head -100 "$RESULTS/perf-report.txt" | grep -E '^\s+[0-9]' | head -20
echo ""
echo "Results saved to $RESULTS/"
echo "done"
