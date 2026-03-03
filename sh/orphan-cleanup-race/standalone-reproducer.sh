#!/usr/bin/env bash
# Reproducer for btrfs orphan_cleanup race
#
# Bug: btrfs_orphan_cleanup() races with concurrent eviction. Eviction deletes
# the orphan item, then orphan_cleanup tries to delete the same item → -ENOENT
# → permanent negative dentry for a valid subvolume.
#
# Requires: dm-delay module, btrfs-progs, python3
# Usage: ./standalone-reproducer.sh <dev>
#   <dev> must be >=12GB block device safe to format

set -euo pipefail

if [ $# -ne 1 ]; then
	echo "usage: $0 <dev>"
	exit 1
fi

DEV=$1
MNT=/mnt/root
DM_NAME="orphan-test-delay"
DM_DEV="/dev/mapper/$DM_NAME"
DELAY_MS=2000

cleanup() {
	cd /
	umount "$MNT" 2>/dev/null || true
	dmsetup remove "$DM_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Load dm-delay
modprobe dm_delay 2>/dev/null || true
if ! dmsetup targets 2>/dev/null | grep -q '^delay'; then
	echo "FATAL: dm-delay target not available"
	exit 1
fi

mkdir -p "$MNT"

# Set up dm-delay with 0ms delay (fast file creation)
SECTORS=$(blockdev --getsz "$DEV")
echo "0 $SECTORS delay $DEV 0 0 $DEV 0 0" | dmsetup create "$DM_NAME"
mkfs.btrfs -f "$DM_DEV" >/dev/null 2>&1
mount "$DM_DEV" "$MNT"

# Create subvolume — d_instantiate, NO btrfs_lookup, ORPHAN_CLEANUP bit never set
btrfs subvolume create "$MNT/testsubvol" >/dev/null

# Create 8GB file (large → 0.85s eviction window during truncation)
echo "Creating 8GB file..."
dd if=/dev/zero of="$MNT/testsubvol/bigfile" bs=1M count=8192 2>/dev/null
sync

# Switch to delayed writes — preserves d_instantiate dentry (no unmount)
echo "Enabling ${DELAY_MS}ms write delay..."
echo "0 $SECTORS delay $DEV 0 0 $DEV 0 $DELAY_MS" | dmsetup reload "$DM_NAME"
dmsetup suspend "$DM_NAME"
dmsetup resume "$DM_NAME"

# Write dirty data, submit async writeback, unlink, close
# sync_file_range creates ordered extents with igrab refs.
# dm-delay keeps them in-flight at close → iput just decrements,
# child dentry killed, parent dentry ref released. No eviction.
echo "Triggering race..."
python3 << 'PYEOF'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open("/mnt/root/testsubvol/bigfile", os.O_RDWR)
chunk = b'\x01' * (1024 * 1024)
for i in range(500):
    os.pwrite(fd, chunk, i * 1024 * 1024)
ret = libc.sync_file_range(ctypes.c_int(fd),
                           ctypes.c_longlong(0),
                           ctypes.c_longlong(500 * 1024 * 1024),
                           ctypes.c_uint(2))  # SYNC_FILE_RANGE_WRITE
if ret != 0:
    sys.exit(1)
os.unlink("/mnt/root/testsubvol/bigfile")
os.close(fd)
PYEOF

# Evict subvolume dentry (child freed at close, parent no longer pinned)
echo 2 > /proc/sys/vm/drop_caches

# Wait for: dm-delay expiry (~2s) + ordered extent workqueue processing
# + cleaner wakeup + eviction to start (but not finish — 0.85s window)
sleep 2.5

# First-ever access triggers btrfs_orphan_cleanup.
# If eviction is in progress: btrfs_iget blocks on I_FREEING → waits →
# eviction deletes orphan → btrfs_iget returns -ENOENT →
# btrfs_del_orphan_item returns -ENOENT → "could not do orphan cleanup -2"
ls "$MNT/testsubvol/" >/dev/null 2>&1 || true

# Check result
echo ""
if dmesg 2>/dev/null | grep -q "could not do orphan cleanup"; then
	echo "BUG REPRODUCED: orphan_cleanup returned -ENOENT"
	dmesg 2>/dev/null | grep "could not do orphan cleanup"
	echo ""
	if ! stat "$MNT/testsubvol" >/dev/null 2>&1; then
		echo "CONFIRMED: stat returns ENOENT (negative dentry cached)"
	fi
else
	echo "Race did not trigger. Retry or adjust sleep value."
	echo "(Eviction window is ~0.85s starting ~2.5s after close)"
fi
