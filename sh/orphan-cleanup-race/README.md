# Orphan Cleanup ENOENT Race Reproducer

## Bug Description

A race condition in `btrfs_orphan_cleanup()` can cause subvolume access to fail
with ENOENT, creating a permanent negative dentry that makes the subvolume
inaccessible.

### Root Cause

In `fs/btrfs/inode.c`, `btrfs_orphan_cleanup()` has a race window between
`iput()` (line 3720) and `btrfs_del_orphan_item()` (line 3732):

```c
if (!inode || inode->i_nlink) {
    if (inode) {
        iput(inode);           // Drops reference
        inode = NULL;
    }
    // <<< RACE WINDOW >>>
    // Another thread can unlink the file, triggering eviction
    // which deletes the orphan item via btrfs_orphan_del()

    trans = btrfs_start_transaction(root, 1);
    ret = btrfs_del_orphan_item(...);  // Returns -ENOENT!
    if (ret)
        goto out;  // Fails the entire subvolume lookup
}
```

### Race Scenario

1. Snapshot B is created from subvolume A (inherits orphan items)
2. Thread 1 accesses B, triggering `btrfs_orphan_cleanup(B)`
3. Cleanup finds orphan for file F, loads inode, sees `i_nlink > 0`
4. Cleanup calls `iput()` - drops reference
5. **Thread 2 unlinks F in B, `i_nlink → 0`, closes file**
6. Thread 2's close triggers eviction → `btrfs_orphan_del()` deletes orphan
7. Thread 1 calls `btrfs_del_orphan_item()` → **ENOENT**
8. Error propagates, negative dentry created for subvolume B

## Reproducer Requirements

### Kernel Patch

Apply the debug delay patch to widen the race window:

```bash
cd /path/to/linux
patch -p1 < patches/btrfs-orphan-cleanup-debug-delay.patch
# Rebuild with CONFIG_BTRFS_DEBUG=y
```

### Enable Delay

```bash
# After booting the patched kernel:
echo 500 > /sys/module/btrfs/parameters/orphan_cleanup_delay_ms
```

## Usage

### Single Iteration (Minimal)

```bash
./standalone-minimal.sh /dev/vdb /mnt/test
```

### Parallel Stress Test

```bash
./parallel-test.sh /dev/vdb /mnt/test 60 4  # 60 seconds, 4 workers
```

## Expected Output on Bug Reproduction

```
*** BUG REPRODUCED! ***
Found 'could not do orphan cleanup -2' (ENOENT) in dmesg

# dmesg shows:
BTRFS error (device vdb): could not do orphan cleanup -2
```

## Proposed Fix

```diff
 ret = btrfs_del_orphan_item(trans, root, found_key.objectid);
 btrfs_end_transaction(trans);
-if (ret)
+if (ret && ret != -ENOENT)  // Already deleted by eviction - not an error
     goto out;
 continue;
```

## Files

- `standalone-minimal.sh` - Single iteration reproducer for sharing
- `parallel-test.sh` - Stress test with multiple workers
- `README.md` - This file

## Related

- dmesg signature: `"could not do orphan cleanup -2"`
- Symptoms: Subvolume shows as `d?????????` in ls, returns ENOENT
- Fix pattern: See `fs/btrfs/verity.c:440-442` for similar ENOENT handling
