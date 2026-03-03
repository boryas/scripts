#!/usr/bin/env bash
# Exploit the 5-second msleep in switch_commit_roots to observe/trigger the gap
#
# During the sleep:
# - Commit root still shows OLD state (holes)
# - CHUNK_ALLOCATED reflects current pending allocations
# - New allocations during this window see the race condition

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

_log "=== Window Race Reproducer ==="
_log "This exploits the 5s msleep before commit root switch"

# Setup fresh filesystem
_log ""
_log "=== Step 1: Setup fresh filesystem ==="
_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"
sysfs=$(_btrfs_sysfs "$dev")
_log "Sysfs: $sysfs"

# Create initial state with data
_log ""
_log "=== Step 2: Create initial data ==="
for i in $(seq 1 8); do
	dd if=/dev/urandom of="$mnt/file_$i" bs=1M count=256 2>/dev/null
done
sync
_log "Initial state committed"

# Show initial committed state
_log ""
_log "Initial committed state:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
fi

# Delete some files to create empty block groups
_log ""
_log "=== Step 3: Delete some files to create empty block groups ==="
rm "$mnt/file_2" "$mnt/file_4" "$mnt/file_6"
_log "Deleted files 2, 4, 6"

# Start balance in background - this will trigger chunk removal
# The balance will cause a commit, which hits our 5s sleep
_log ""
_log "=== Step 4: Start balance and exploit the 5s window ==="
_log "Starting balance (will hit 5s sleep during commit)..."

# Start balance in background
btrfs balance start -dusage=5 "$mnt" &
balance_pid=$!

# Wait a moment for balance to start processing
sleep 1

# Watch for the pr_info message indicating we're in the sleep window
_log "Waiting for commit sleep window (watch dmesg)..."
for i in $(seq 1 15); do
	if dmesg | tail -5 | grep -q "sleeping 5s before root swap"; then
		_log "*** IN COMMIT WINDOW! Forcing allocations now! ***"

		# During this window:
		# - Commit root = old state (with holes where deleted chunks were)
		# - CHUNK_ALLOCATED = current state (balance removed chunks clear bits)
		# - New allocations see old commit root but use CHUNK_ALLOCATED

		# Force multiple allocations rapidly
		echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null &
		echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null &
		echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null &
		echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null &

		# Observe state during window
		sleep 1
		_log "State during commit window:"
		if command -v drgn &>/dev/null; then
			drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
		fi
		break
	fi
	sleep 1
done

# Wait for balance to complete
_log ""
_log "Waiting for balance to complete..."
wait $balance_pid 2>/dev/null || true

# Check for errors
_log ""
_log "=== Checking for errors ==="
if dmesg | tail -100 | grep -q "errno=-17\|EEXIST\|Object already exists"; then
	_sad "FOUND EEXIST ERROR!"
	dmesg | grep -E "errno=-17|EEXIST|Object already exists" | tail -10
else
	_log "No EEXIST errors in recent dmesg"
fi

# Final state
_log ""
_log "Final state:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null || true
fi

_log ""
_log "=== Done ==="
