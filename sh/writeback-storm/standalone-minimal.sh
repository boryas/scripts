#!/usr/bin/env bash
# Standalone minimal reproducer for btrfs writeback storm metadata stall
#
# Reproduces the preemptive reclaim feedback loop where FLUSH_DELALLOC
# generates delayed refs via COW, increasing bytes_may_use, triggering
# more FLUSH_DELALLOC — a positive feedback loop that causes system-wide
# filesystem stalls.
#
# The workload piles up a large amount of dirty data by disabling the
# periodic flusher and raising dirty thresholds, then writes continuously
# to trigger a writeback storm. The btrfs preemptive reclaim picks
# FLUSH_DELALLOC to reduce bytes_may_use, but COW amplification from
# writeback generates more delayed refs than it drains.
#
# Symptoms when reproduced:
#   - clamp escalates to 8 (check via drgn or bpftrace)
#   - unrelated metadata ops (mkdir, stat, open w/ relatime) block in
#     __reserve_bytes for seconds to minutes
#   - bpftrace flush_effectiveness.bt shows preemptive DELALLOC with
#     negative bytes_may_use freed (INCREASED it)
#
# Usage: $0 <dev> <mnt> [file_size_gb]
#
# For mkosi-kernel VMs where / is btrfs:
#   $0 /dev/vda2 / 100
#
# Self-contained, zero dependencies. Safe to share externally.

set -e

if [ $# -lt 2 ]; then
	echo "usage: $0 <dev> <mnt> [file_size_gb]"
	echo ""
	echo "  dev          - block device (for remount and balance)"
	echo "  mnt          - btrfs mount point"
	echo "  file_size_gb - total data to write (default: 100)"
	echo ""
	echo "Must be run as root. Filesystem must already be mounted."
	echo "Run reset.sh between runs to clear state."
	exit 1
fi

dev=$1
mnt=$2
file_size_gb=${3:-100}

workdir="$mnt/writeback-storm"
seed_file="$workdir/urandom"
target_file="$workdir/urandom.copy"

MONITOR_PID=""
WRITER_PID=""

cleanup() {
	echo "[*] Cleaning up..."
	[ -n "$WRITER_PID" ] && kill "$WRITER_PID" 2>/dev/null || true
	[ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null || true
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# --- Tuning ---
echo "[*] Applying VM dirty tunables..."
sysctl -w vm.dirty_background_ratio=60 >/dev/null
sysctl -w vm.dirty_ratio=80 >/dev/null
sysctl -w vm.dirty_writeback_centisecs=0 >/dev/null
sysctl -w vm.dirty_expire_centisecs=360000 >/dev/null

echo "[*] Remounting with commit=9999999..."
mount -o remount,commit=9999999 "$mnt"

# --- Preparation ---
mkdir -p "$workdir"

if [ ! -f "$seed_file" ]; then
	echo "[*] Generating 1G seed file from /dev/urandom..."
	head -c 1G /dev/urandom > "$seed_file"
	sync
fi

# --- Monitoring ---
echo "[*] Starting meminfo monitor (5s interval)..."
(
	while true; do
		ts=$(date +%H:%M:%S)
		dirty=$(grep -i "^Dirty:" /proc/meminfo | awk '{print $2, $3}')
		writeback=$(grep -i "^Writeback:" /proc/meminfo | awk '{print $2, $3}')
		echo "$ts  Dirty: $dirty  Writeback: $writeback"
		sleep 5
	done
) &
MONITOR_PID=$!

# --- Workload ---
rm -f "$target_file"
echo "[*] Starting writeback storm: writing ${file_size_gb}G to $target_file"
echo "[*] Monitor PID: $MONITOR_PID"
echo "[*] Press Ctrl-C to stop early."
echo ""

# Write seed_file repeatedly until we hit the target size.
# Each iteration appends 1G.
iterations=$file_size_gb
bytes_written=0

for i in $(seq 1 "$iterations"); do
	cat "$seed_file" >> "$target_file"
	bytes_written=$((bytes_written + 1))
	echo "[writer] ${bytes_written}G / ${file_size_gb}G written"
done

echo ""
echo "[*] Write phase complete. Syncing..."
sync
echo "[*] Sync complete."

# --- Post-workload state ---
echo ""
echo "=== Post-workload state ==="
grep -i -e "^Dirty:" -e "^Writeback:" /proc/meminfo
echo ""
echo "btrfs fi usage:"
btrfs filesystem usage "$mnt" 2>/dev/null | head -15 || true
echo ""
echo "[*] Done. Run reset.sh before next iteration."
echo "[*] For detailed flush analysis, run flush_effectiveness.bt in parallel."
