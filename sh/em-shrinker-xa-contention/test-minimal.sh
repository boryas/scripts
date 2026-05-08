#!/usr/bin/env bash
# Run inside the VM to test the minimal reproducer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== starting tracing ==="
timeout 120 bpftrace -e '
  kprobe:find_first_inode_to_shrink { @start[tid]=nsecs; }
  kretprobe:find_first_inode_to_shrink /@start[tid]/ {
    @shrinker_us=hist((nsecs-@start[tid])/1000); delete(@start[tid]);
  }
  kprobe:btrfs_destroy_inode { @di_start[tid]=nsecs; }
  kretprobe:btrfs_destroy_inode /@di_start[tid]/ {
    @destroy_us=hist((nsecs-@di_start[tid])/1000); delete(@di_start[tid]);
  }
  kprobe:btrfs_extent_map_shrinker_worker { @shrinker_calls++; }
' > /tmp/bt.out 2>&1 &
BT=$!

perf record -ag -o /tmp/perf.data -- sleep 90 &
PERF=$!
sleep 2

NR=200000 bash "$SCRIPT_DIR/standalone-minimal-share.sh" /dev/vda /tmp/mnt &
REPRO=$!

echo "waiting for eviction window..."
sleep 60

echo "=== inode-state ==="
cat /proc/sys/fs/inode-state

kill -INT $BT 2>/dev/null; wait $BT 2>/dev/null || true
kill -INT $PERF 2>/dev/null; wait $PERF 2>/dev/null || true

echo "=== bpftrace ==="
grep -v -E '^[EIW]0|SmcTiers|Dropping|connect|Producer|Retry|ODS|\.cpp:|stdin:|WARNING' /tmp/bt.out || true

echo "=== perf: spinlock contention stacks ==="
perf report -i /tmp/perf.data --stdio --no-children -g fractal,5 \
  --percent-limit 0.01 2>/dev/null | \
  grep -B3 -A15 'pv_queued_spin_lock_slowpath\|kvm_wait\|pv_native_safe_halt' | \
  grep -A15 'btrfs_destroy_inode\|btrfs_del_inode' | head -40 || echo "(none)"
echo "=== pressure ==="
cat /proc/pressure/memory

echo "=== inode-state ==="
cat /proc/sys/fs/inode-state
grep pgscan_kswapd /proc/vmstat

kill $REPRO 2>/dev/null; wait 2>/dev/null || true
