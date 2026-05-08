#!/usr/bin/env sh
# Reset state between writeback storm runs.
# Usage: reset.sh [mnt]   (default: /)

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")

mnt=${1:-/}
commit=${2:-10}
workdir="$mnt/writeback-storm"

echo "[*] Cleaning workload files..."
rm -f "$workdir/urandom.copy"

echo "[*] Reclaiming empty block groups..."
btrfs balance start -dusage=0 "$mnt" 2>/dev/null || true
btrfs balance start -musage=0 "$mnt" 2>/dev/null || true

echo "[*] Resetting clamp via drgn..."
drgn "$DIR/reset-clamp.py" 2>/dev/null || echo "  (drgn not available, skipping clamp reset)"

echo "[*] Applying VM dirty tunables..."
sysctl -w vm.dirty_background_ratio=60
sysctl -w vm.dirty_ratio=80
sysctl -w vm.dirty_writeback_centisecs=0
sysctl -w vm.dirty_expire_centisecs=360000

echo "[*] Setting commit interval to $commit"
mount -o remount,commit=$commit /
btrfs filesystem sync /
sleep 1
btrfs filesystem sync /
echo "[*] Reset complete."

echo "[*] Reset complete."
