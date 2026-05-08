#!/usr/bin/env bash
# Force periodic commits during a writeback storm to reproduce the
# commit/reclaim collision that causes tail latency.
#
# Usage: commit_stall_repro.sh <size_gb> [interval_s]
#
# Run commit_oe_burst.bt in a separate terminal for analysis.

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
BABY="$SCRIPT_DIR/baby.sh"

size_gb=${1:-300}
interval=${2:-30}
stop_file="/tmp/commit_stall_stop"

echo "[*] Resetting..."
"$BABY" reset

rm -f "$stop_file"

echo "[*] Starting sync loop every ${interval}s (stop file: $stop_file)..."
(
	while [ ! -f "$stop_file" ]; do
		sleep "$interval"
		[ -f "$stop_file" ] && break
		dirty=$(awk '/^Dirty:/{print int($2/1024)}' /proc/meminfo)
		echo "[sync] Dirty: ${dirty}MB. Forcing commit..."
		btrfs fi sync /
	done
) &
SYNC_PID=$!

echo "[*] Starting ${size_gb}G write..."
"$BABY" "$size_gb"

touch "$stop_file"
wait $SYNC_PID 2>/dev/null
rm -f "$stop_file"
echo "[*] Done."
