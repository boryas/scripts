#!/usr/bin/env bash
# Reproducer for dev extent race bug - same transaction version
#
# Strategy:
# 1. Start with committed state (some allocations)
# 2. Force allocate multiple chunks (all pending, not in commit root)
# 3. Write files to fill some, then delete to make them empty
# 4. Let cleaner remove the empty ones (clears CHUNK_ALLOCATED)
# 5. Force more allocations - should hit bug if gaps exist
#
# The key insight: if chunks are created AND removed in the same transaction,
# commit root shows the old state (big hole) but bitmap shows gaps.

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

_log "=== Same-Transaction Gap Reproducer ==="
_log "Device: $dev"
_log "Mount: $mnt"

# Setup fresh filesystem
_log ""
_log "=== Step 1: Setup fresh filesystem ==="
_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"

sysfs=$(_btrfs_sysfs "$dev")
_log "Sysfs: $sysfs"

# Step 2: Create initial allocation pattern to have a known state
_log ""
_log "=== Step 2: Create initial state with some data ==="
dd if=/dev/urandom of="$mnt/initial" bs=1M count=256 2>/dev/null
sync
_log "Initial sync done - commit root now has some allocations"

# Show initial state
_log ""
_log "Initial state (committed):"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
fi

# Step 3: Force allocate multiple data chunks (all pending)
_log ""
_log "=== Step 3: Force allocate 3 data chunks (all pending) ==="
_log "Forcing data chunk 1..."
echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null || true
_log "Forcing data chunk 2..."
echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null || true
_log "Forcing data chunk 3..."
echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null || true

_log ""
_log "After forcing 3 data allocations (pending, no sync):"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
fi

# Step 4: Write files to specifically fill chunk 2, then delete to make it empty
# This is tricky because we don't control which chunk files go to.
# Alternative: Use balance to remove empty chunks within the transaction
_log ""
_log "=== Step 4: Try to create gap by removing middle chunk ==="

# Write a small file to keep chunk 1 non-empty
dd if=/dev/urandom of="$mnt/keep1" bs=1M count=10 2>/dev/null
# Write to fill chunk 2
dd if=/dev/urandom of="$mnt/remove" bs=1M count=500 2>/dev/null
# Write to keep chunk 3 non-empty
dd if=/dev/urandom of="$mnt/keep2" bs=1M count=10 2>/dev/null

_log "Deleting middle file to empty chunk 2..."
rm "$mnt/remove"

# Try to trigger cleaner without full sync
# The bg_reclaim_threshold controls automatic removal
_log "Triggering block group reclaim..."
echo 0 > "$sysfs/allocation/data/bg_reclaim_threshold" 2>/dev/null || true

# Try balance -dusage=0 to remove empty block groups
# But this might cause a commit...
_log "Running balance -dusage=0 (may commit)..."
btrfs balance start -dusage=0 "$mnt" 2>&1 || true

_log ""
_log "State after attempted gap creation:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
fi

# Step 5: Force more allocations to try to trigger bug
_log ""
_log "=== Step 5: Force DUP allocation to try to trigger bug ==="
echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null || true

_log ""
_log "Final state:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null || true
fi

# Check for errors
_log ""
_log "=== Checking for errors ==="
if dmesg | tail -100 | grep -q "errno=-17\|EEXIST\|Object already exists"; then
	_sad "FOUND EEXIST ERROR!"
	dmesg | grep -E "errno=-17|EEXIST|Object already exists" | tail -10
else
	_log "No EEXIST errors in recent dmesg"
fi

_log ""
_log "=== Done ==="
