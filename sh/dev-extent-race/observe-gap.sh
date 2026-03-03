#!/usr/bin/env bash
# Exploit the 5-second msleep to observe the gap
#
# Strategy:
# 1. Create filesystem with some chunks
# 2. Delete files to mark some block groups empty
# 3. Start balance (removes empty BGs, triggers commit with sleep)
# 4. During the 5s window, rapidly dump state to observe:
#    - Commit root still has old chunks (or holes)
#    - CHUNK_ALLOCATED reflects balance's chunk removal
#
# The goal is to observe the gap between committed and pending state

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

_log "=== Observe Gap During Commit ==="

# Setup
_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"
sysfs=$(_btrfs_sysfs "$dev")

# Create multiple data chunks
_log "Creating data to fill multiple chunks..."
for i in $(seq 1 6); do
	dd if=/dev/urandom of="$mnt/file_$i" bs=1M count=300 2>/dev/null
done
sync

_log "State after initial data:"
drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true

# Delete some files to create empty block groups
_log ""
_log "Deleting files 2, 3, 4 to empty those block groups..."
rm "$mnt/file_2" "$mnt/file_3" "$mnt/file_4"
sync

_log "State after deletion (BGs marked empty but not removed):"
drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true

# Now start balance which will remove empty BGs and hit the 5s sleep
_log ""
_log "Starting balance to remove empty BGs (will hit 5s sleep)..."
_log "Watch the state dumps during the sleep window!"

# Start balance
btrfs balance start -dusage=1 "$mnt" &
balance_pid=$!

# Poll for the sleep message and dump state during the window
for i in $(seq 1 20); do
	if dmesg | tail -3 | grep -q "sleeping 5s"; then
		_log ""
		_log "*** COMMIT WINDOW DETECTED - Dumping state ***"
		_log ""

		# Dump multiple times during the window
		for j in 1 2 3; do
			_log "=== Dump $j during commit window ==="
			drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
			sleep 1
		done
		break
	fi
	sleep 0.5
done

wait $balance_pid 2>/dev/null || true

_log ""
_log "State after balance:"
drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true

_log ""
_log "Checking for errors..."
dmesg | tail -50 | grep -E "errno=-17|EEXIST" && _sad "EEXIST found!" || _log "No EEXIST"

_log "=== Done ==="
