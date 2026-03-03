#!/usr/bin/env bash
# Observe gap during commit - with larger files to ensure separate chunks
#
# Each 1GB file should go into its own data chunk

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 2 ]; then
	echo "Usage: $0 <dev> <mnt>"
	exit 1
fi

dev=$1
mnt=$2

_log "=== Observe Gap During Commit (Large Files) ==="

# Setup
_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"
sysfs=$(_btrfs_sysfs "$dev")

# Create 4 x 1GB files - each should get its own chunk
_log "Creating 4 x 1GB files (each in separate chunk)..."
for i in 1 2 3 4; do
	_log "  Creating file_$i..."
	dd if=/dev/urandom of="$mnt/file_$i" bs=1M count=1024 2>/dev/null
	sync  # Force sync after each to ensure separate chunks
done

_log ""
_log "State after creating 4 files:"
drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null | head -30 || true

# Delete files 2 and 3 to empty those chunks
_log ""
_log "Deleting files 2 and 3..."
rm "$mnt/file_2" "$mnt/file_3"
sync

_log ""
_log "State after deletion (chunks 2, 3 should be empty):"
btrfs filesystem df "$mnt"

# Now balance to remove empty chunks - this hits the 3s sleep after clearing CHUNK_ALLOCATED
_log ""
_log "Starting balance -dusage=0 to remove empty chunks..."

# Record dmesg length BEFORE starting balance
dmesg_before=$(dmesg | wc -l)

# Start a background watcher that will dump state when it sees the message
(
	for i in $(seq 1 300); do
		if dmesg | tail -n +$dmesg_before | grep -q "btrfs_remove_chunk_map sleeping"; then
			_log ""
			_log "*** CHUNK REMOVAL WINDOW DETECTED! ***"
			_log ""
			_log "CHUNK_ALLOCATED bitmap:"
			drgn /work/src/scripts/drgn/dump_chunk_allocated.py "$mnt" 2>/dev/null || true
			_log ""
			_log "COMMIT ROOT vs CURRENT ROOT dev_extents:"
			drgn /work/src/scripts/drgn/dump_dev_extents_btree.py "$mnt" 2>/dev/null || true
			_log ""
			_log "Allocator view (comparing commit root vs current):"
			drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
			break
		fi
		sleep 0.05
	done
) &
watcher_pid=$!

# Now start balance
btrfs balance start -dusage=0 "$mnt" &
balance_pid=$!

_log "Watching for btrfs_remove_chunk_map sleep (3s window)..."

# Wait for balance to finish
wait $balance_pid 2>/dev/null || true

# Give watcher a moment to finish if it caught the message
sleep 1
kill $watcher_pid 2>/dev/null || true

_log ""
_log "Final state:"
drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null || true

dmesg | tail -30 | grep -E "errno=-17|EEXIST" && _sad "EEXIST!" || _log "No EEXIST"
_log "=== Done ==="
