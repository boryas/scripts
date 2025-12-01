# Btrfs Simple Quotas (squota) Inheritance Bug Reproducers

Bug: Level 1 qgroups retain metadata usage after all members are removed in a 2-level qgroup hierarchy with `--inherit`.

## Scripts

### standalone-minimal.sh - FOR SHARING VIA EMAIL
**Purpose**: Completely standalone reproducer with zero dependencies. Share this with kernel developers.

**Usage**:
```bash
./standalone-minimal.sh <dev> <mnt>
```

**Features**:
- Single iteration
- No dependencies on helper functions or boilerplate
- Uses `btrfs subvolume sync` for clean deletion waiting
- 69 lines of pure bash
- Reproduces bug deterministically

### btrfs-squota-bug-minimal.sh - FOR REPO USE
**Purpose**: Minimal reproducer using repo boilerplate patterns.

**Usage**:
```bash
./btrfs-squota-bug-minimal.sh <dev> <mnt>
```

**Pattern**:
- Single iteration
- Uses standard boilerplate functions (_log, _sad, _happy, etc.)
- Integrates with repo patterns
- Reproduces bug deterministically

### parallel-test.sh - FOR STRESS TESTING
**Purpose**: Parallel workload to stress test the bug with concurrent operations.

**Usage**:
```bash
./parallel-test.sh <dev> <mnt> <duration_seconds> <num_workers>
# Example: ./parallel-test.sh /dev/nvme1n1 /mnt/test 30 4
```

**Pattern**:
- Multiple parallel workers
- Each worker creates/destroys Q1X hierarchies repeatedly
- Reproduces bug under concurrent load
- Good for validating fixes under stress

## Bug Pattern

The bug requires:
1. 2-level qgroup hierarchy (Q2 at level 2, Q11 at level 1)
2. Base subvolume added to Q2
3. **Intermediate snapshot manually added to Q11** (critical!)
4. Working snapshot created from intermediate with `--inherit Q11`
5. Delete snapshot and wait for full deletion quiescence
6. **Bug**: Q11 has 16 KiB (1x16K nodesize) leaked usage with no members

## Helper Functions

See `/home/borisb/local/scripts/sh/squota.sh` for shared squota helper functions:
- `_fresh_squota_mnt` - Setup fresh btrfs with simple quotas
- `_wait_for_deletion` - Wait for subvolume deletions to complete
- `_check_qgroup_leak` - Check if qgroup has leaked usage
