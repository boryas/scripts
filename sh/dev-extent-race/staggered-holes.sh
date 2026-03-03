#!/usr/bin/env bash
# Non-parallel reproducer for dev extent race bug
#
# Creates a staggered pattern of holes in device extent space:
# 1. Write 32 x 256MB files (fills ~8GB, creates multiple block groups)
# 2. Sync to commit
# 3. Delete all files except those with id % 8 == 0 (keep 0, 8, 16, 24)
# 4. Trigger cleaner to remove empty block groups
#
# This creates a pattern like:
#   [BG with file0] [empty] [empty] ... [empty] [BG with file8] [empty] ...
#
# After cleaner runs, we have gaps in the physical address space.

# Note: not using set -e to allow continuing past non-fatal errors

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 2 ]; then
	echo "Usage: $0 <dev> <mnt> [file_size_mb] [num_files]"
	echo ""
	echo "Arguments:"
	echo "  dev          - Block device to use"
	echo "  mnt          - Mount point"
	echo "  file_size_mb - Size of each file in MB (default: 256)"
	echo "  num_files    - Number of files to create (default: 32)"
	echo ""
	echo "Files with id % 8 == 0 will be kept, others deleted."
	exit 1
fi

dev=$1
mnt=$2
file_size_mb=${3:-256}
num_files=${4:-32}
keep_mod=${5:-8}  # Keep files 0, 8, 16, 24

_log "=== Dev Extent Race Reproducer (Non-Parallel) ==="
_log "Device: $dev"
_log "Mount: $mnt"
_log "File size: ${file_size_mb}MB"
_log "Num files: $num_files"
_log "Keep files where id % $keep_mod == 0"

# Setup fresh filesystem
_log ""
_log "=== Step 1: Setup fresh filesystem ==="
_umount_loop "$dev"
_fresh_btrfs_mnt "$dev" "$mnt"

sysfs=$(_btrfs_sysfs "$dev")
_log "Sysfs: $sysfs"

# Step 2: Create files
_log ""
_log "=== Step 2: Creating $num_files x ${file_size_mb}MB files ==="

for i in $(seq 0 $((num_files - 1))); do
	printf "\r  Creating file %02d/%02d..." "$((i + 1))" "$num_files"
	dd if=/dev/urandom of="$mnt/file_$(printf '%02d' $i)" \
		bs=1M count="$file_size_mb" 2>/dev/null
done
echo ""

_log "Files created. Syncing..."
sync

_log ""
_log "=== Step 3: Initial filesystem state ==="
btrfs filesystem df "$mnt"
echo ""
btrfs filesystem usage "$mnt" 2>/dev/null | head -20 || true

# Dump chunk maps before deletion
_log ""
_log "Chunk maps before deletion:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null | head -40 || true
fi

# Step 4: Delete files to create staggered pattern
_log ""
_log "=== Step 4: Deleting files to create staggered holes ==="
_log "Keeping files: $(for i in $(seq 0 $((num_files - 1))); do [ $((i % keep_mod)) -eq 0 ] && echo -n "file_$(printf '%02d' $i) "; done)"

deleted=0
for i in $(seq 0 $((num_files - 1))); do
	if [ $((i % keep_mod)) -ne 0 ]; then
		rm "$mnt/file_$(printf '%02d' $i)"
		((deleted++))
	fi
done

_log "Deleted $deleted files"
_log "Syncing deletion..."
sync

_log ""
_log "Filesystem state after deletion (before cleaner):"
btrfs filesystem df "$mnt"

# Step 5: Trigger cleaner thread to remove empty block groups
_log ""
_log "=== Step 5: Triggering cleaner thread ==="

# Use balance -dusage=0 to only relocate completely empty block groups
# This avoids moving data around - it just marks empty BGs for removal
_log "Running balance -dusage=0 to remove empty block groups..."
btrfs balance start -dusage=0 "$mnt" 2>&1 || true

_log "Syncing..."
sync

# Wait for cleaner to process
_log "Waiting for cleaner thread (3 seconds)..."
sleep 3
sync

_log ""
_log "=== Step 6: Filesystem state after cleaner ==="
btrfs filesystem df "$mnt"
echo ""
btrfs filesystem usage "$mnt" 2>/dev/null | head -20 || true

# Dump chunk maps after cleaner
_log ""
_log "Chunk maps after cleaner:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null | head -60 || true
fi

# Dump CHUNK_ALLOCATED bits
_log ""
_log "CHUNK_ALLOCATED bitmap:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_allocated.py "$mnt" 2>/dev/null || true
fi

# Step 7: Now we have holes - force allocations to test the bug
_log ""
_log "=== Step 7: Force chunk allocations (no sync between!) ==="

# First, force a 1GB data allocation - this will be pending (not in commit root)
_log "Forcing data chunk allocation (1GB, pending)..."
echo 1 > "$sysfs/allocation/data/force_chunk_alloc" 2>/dev/null || true

# DO NOT SYNC! We want the data allocation to remain pending (not in commit root)
# The DUP allocation below should see a larger hole in commit root
# but contains_pending_extent should catch the pending data allocation

# Check commit root vs current root
_log ""
_log "Checking commit_root vs current root (should differ if pending allocation exists):"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/show_allocator_view.py "$mnt" 2>/dev/null || true
fi

_log ""
_log "Forcing metadata chunk allocation (DUP, 2x256MB = 512MB)..."
echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null || true

_log "Forcing second metadata chunk allocation (DUP)..."
echo 1 > "$sysfs/allocation/metadata/force_chunk_alloc" 2>/dev/null || true

# Check state BEFORE sync - these are all pending allocations
_log ""
_log "CHUNK_ALLOCATED bitmap BEFORE sync (pending allocations):"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_allocated.py "$mnt" 2>/dev/null || true
fi

_log ""
_log "Chunk maps BEFORE sync (pending allocations):"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null | head -50 || true
fi

# Now sync to commit everything
_log ""
_log "Syncing all pending allocations..."
sync

# Final state
_log ""
_log "=== Step 8: Final state ==="

_log "Chunk maps after forced allocation:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_maps.py "$mnt" 2>/dev/null || true
fi

_log ""
_log "CHUNK_ALLOCATED bitmap after forced allocation:"
if command -v drgn &>/dev/null; then
	drgn /work/src/scripts/drgn/dump_chunk_allocated.py "$mnt" 2>/dev/null || true
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
_log "Mount point left mounted at: $mnt"
_log "You can inspect with:"
_log "  drgn /work/src/scripts/drgn/dump_chunk_maps.py $mnt"
_log "  drgn /work/src/scripts/drgn/dump_chunk_allocated.py $mnt"
