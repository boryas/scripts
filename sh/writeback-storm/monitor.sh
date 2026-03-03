#!/usr/bin/env bash
# Monitor script for writeback storm reproduction.
# Run in a separate terminal alongside the workload.
#
# Tracks:
#   - Dirty / Writeback from /proc/meminfo
#   - btrfs metadata space_info via sysfs
#   - Optional: flush_effectiveness.bt (if bpftrace available)
#
# Usage: monitor.sh [mnt] [interval_sec]

set -e

mnt=${1:-/}
interval=${2:-5}

dev=$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || echo "")
uuid=$(btrfs filesystem show "$mnt" 2>/dev/null | grep -o 'uuid: .*' | awk '{print $2}' || echo "")
sysfs_meta="/sys/fs/btrfs/$uuid/allocation/metadata"

BPFTRACE_PID=""

cleanup() {
	[ -n "$BPFTRACE_PID" ] && kill -INT "$BPFTRACE_PID" 2>/dev/null || true
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# --- Header ---
echo "=== Writeback Storm Monitor ==="
echo "Mount: $mnt  Device: $dev  UUID: $uuid"
echo "Interval: ${interval}s"
echo ""

# --- Optional bpftrace ---
FLUSH_BT=""
for p in \
	"$(dirname "$(readlink -f "$0")")/../../../local/scripts/bt/flush_effectiveness.bt" \
	"/work/src/scripts/bt/flush_effectiveness.bt" \
	"$HOME/local/scripts/bt/flush_effectiveness.bt"; do
	if [ -f "$p" ]; then
		FLUSH_BT="$p"
		break
	fi
done

if [ -n "$FLUSH_BT" ] && command -v bpftrace >/dev/null 2>&1; then
	echo "[*] Starting flush_effectiveness.bt -> /tmp/flush_effectiveness.out"
	bpftrace "$FLUSH_BT" > /tmp/flush_effectiveness.out 2>&1 &
	BPFTRACE_PID=$!
	sleep 2
	if ! kill -0 "$BPFTRACE_PID" 2>/dev/null; then
		echo "[!] bpftrace failed (check /tmp/flush_effectiveness.out)"
		BPFTRACE_PID=""
	fi
else
	echo "[*] bpftrace or flush_effectiveness.bt not found, monitoring meminfo only"
fi

echo ""
printf "%-10s %12s %12s" "TIME" "DIRTY" "WRITEBACK"
if [ -d "$sysfs_meta" ]; then
	printf " %14s %14s" "META_USED" "META_TOTAL"
fi
echo ""

# --- Monitor loop ---
while true; do
	ts=$(date +%H:%M:%S)
	dirty=$(awk '/^Dirty:/ {print $2}' /proc/meminfo)
	writeback=$(awk '/^Writeback:/ {print $2}' /proc/meminfo)

	printf "%-10s %10s kB %10s kB" "$ts" "$dirty" "$writeback"

	if [ -d "$sysfs_meta" ]; then
		used=$(cat "$sysfs_meta/bytes_used" 2>/dev/null || echo 0)
		total=$(cat "$sysfs_meta/disk_total" 2>/dev/null || echo 0)
		used_mb=$((used / 1048576))
		total_mb=$((total / 1048576))
		printf " %10s MB %10s MB" "$used_mb" "$total_mb"
	fi

	echo ""
	sleep "$interval"
done
