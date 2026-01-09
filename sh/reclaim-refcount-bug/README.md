# Reclaim + Relocation Block Group Refcount Bug

## Bug Description

Block group refcount leak when dynamic/periodic reclaim triggers relocation that hits ENOSPC during block group cache truncation.

The bug involves a race between:
1. The periodic/dynamic reclaim worker (`btrfs_reclaim_bgs_work`)
2. The relocation code (`btrfs_relocate_block_group`)

When reclaim selects a block group for relocation and relocation fails with ENOSPC during cache truncation (specifically in `delete_block_group_cache`), both code paths may attempt to put the block group reference, potentially leading to a refcount leak or use-after-free.

## Debug Instrumentation

The kernel has been instrumented with debug printks:

**In `fs/btrfs/relocation.c` (`delete_block_group_cache`):**
```c
ret = btrfs_check_trunc_cache_free_space(fs_info, &fs_info->global_block_rsv);
printk(KERN_INFO "BO: %d inject enospc... bg %llu\n", current->pid, block_group->start);
ret = -ENOSPC;  // Manual ENOSPC injection
```

**In `fs/btrfs/relocation.c` (`btrfs_relocate_block_group`):**
```c
out_put_bg:
    printk(KERN_INFO "BO: %d reloc put bg\n", current->pid);
    btrfs_put_block_group(bg);
    printk(KERN_INFO "BO: %d reloc put bg done\n", current->pid);
```

**In `fs/btrfs/block-group.c` (`btrfs_reclaim_bgs_work`):**
```c
next:
    if (ret && !READ_ONCE(space_info->periodic_reclaim))
        btrfs_link_bg_list(bg, &retry_list);
    printk(KERN_INFO "BO: %d reclaim loop put bg\n", current->pid);
    btrfs_put_block_group(bg);
    printk(KERN_INFO "BO: %d reclaim loop put bg done\n", current->pid);
```

## Reproducer Scripts

### 1. `standalone-minimal.sh`
**Purpose:** Self-contained reproducer for sharing externally

**Usage:**
```bash
./standalone-minimal.sh <dev> <mnt>
```

**Characteristics:**
- Zero dependencies, pure bash
- ~120 lines
- Single iteration through bug-triggering sequence
- Can run anywhere without the scripts repository

### 2. `reclaim-refcount-minimal.sh`
**Purpose:** Internal use, follows repository patterns

**Usage:**
```bash
./reclaim-refcount-minimal.sh <dev> <mnt>
```

**Characteristics:**
- Uses repository boilerplate functions
- Integrates with shared helpers
- Single iteration, deterministic
- Easier to maintain alongside other reproducers

### 3. `parallel-test.sh`
**Purpose:** Stress test with concurrent operations

**Usage:**
```bash
./parallel-test.sh <dev> <mnt> <duration_seconds> <num_workers>

# Example: Run with 4 workers for 60 seconds
./parallel-test.sh /dev/vdb /mnt/test 60 4
```

**Characteristics:**
- Multiple parallel file I/O workers
- Concurrent balance operations
- Runs for specified duration
- More likely to trigger race conditions
- Good for validating fixes under stress

## How the Reproducers Work

### Common Pattern

All reproducers follow this sequence:

1. **Setup filesystem with reclaim enabled:**
   - Create fresh btrfs filesystem
   - Enable both `dynamic_reclaim` and `periodic_reclaim` via sysfs

2. **Fill filesystem to trigger reclaim:**
   - Write files to ~80-95% full
   - This ensures multiple block groups exist
   - Creates conditions where reclaim will select block groups

3. **Create fragmentation:**
   - Delete some files to free space within block groups
   - Makes certain block groups good reclaim candidates

4. **Trigger reclaim:**
   - Write more data to trigger reclaim threshold
   - Force filesystem sync to wake reclaim worker
   - Reclaim worker selects underfull block groups for relocation

5. **Hit ENOSPC injection:**
   - Relocation starts on selected block group
   - Hits forced ENOSPC in `delete_block_group_cache`
   - Both reclaim and relocation may try to put the block group

6. **Check for bug:**
   - Examine dmesg for debug output
   - Look for interleaved "reloc put bg" and "reclaim loop put bg" messages
   - Same block group address in both indicates potential double-put

### Parallel Test Additional Behavior

The parallel test adds:
- **File churn workers:** Continuously write/delete files to maintain high allocation pressure
- **Balance worker:** Competes with reclaim for block group selection
- **Random delays:** Desynchronizes workers to hit different race windows
- **Extended duration:** Runs for configurable time to increase probability of hitting the race

## Expected Output

### Success (Bug Reproduced)

Look for dmesg output like:
```
BO: 1234 inject enospc... bg 1234567890
BO: 1234 reloc put bg
BO: 5678 reclaim loop put bg
BO: 1234 reloc put bg done
BO: 5678 reclaim loop put bg done
```

If you see both relocation and reclaim putting the same block group (indicated by the bg address in the inject message), the bug may be present.

### What to Check

1. **ENOSPC injection:** Confirms relocation hit the failure path
2. **PIDs:** Different PIDs indicate different code paths operating concurrently
3. **Interleaving:** Messages from reloc and reclaim interleaved suggests race
4. **Timing:** "put bg done" messages help determine if operations overlapped

## Testing in VM

### Setup VM (one-time)
```bash
cd ~/local/mkosi-kernel
LLVM=1 mkosi build -f
```

### Launch VM
```bash
# Terminal 1: Launch VM
cd ~/local/mkosi-kernel
LLVM=1 mkosi qemu

# Terminal 2: SSH into VM
mkosi ssh
```

### Identify Safe Block Device
```bash
lsblk -f
# Pick an unmounted device, commonly /dev/vdb or /dev/vdc
```

### Run Reproducer
```bash
# In VM, scripts are at /work/src/scripts/sh/
cd /work/src/scripts/sh/reclaim-refcount-bug

# Simple minimal version
./reclaim-refcount-minimal.sh /dev/vdb /mnt/test

# Or parallel stress test
./parallel-test.sh /dev/vdb /mnt/test 60 4
```

### Monitor Results
```bash
# Watch dmesg in real-time
dmesg -w | grep 'BO:'

# Or check after test completes
dmesg | grep -E 'BO:|btrfs' | tail -100
```

## Notes

- The reproducers leave extensive debug output in dmesg for analysis
- Manual ENOSPC injection ensures we always hit the failure path
- Real-world bug would occur randomly when actual ENOSPC happens during cache truncation
- The parallel test increases likelihood of hitting race conditions
- Filesystem is cleaned up after each run (unmounted)
