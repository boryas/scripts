#!/usr/bin/env drgn
"""
Verify CHUNK_ALLOCATED bitmap against actual chunk maps and commit root dev extents.

This script compares:
1. CHUNK_ALLOCATED bitmap - tracks pending allocations
2. Chunk maps in memory - current view of all chunks
3. Dev extents in commit_root - what find_free_dev_extent() sees

To identify any inconsistencies that could lead to the EEXIST bug.

Usage:
    drgn scripts/drgn/verify_chunk_allocated.py <mountpoint>
"""

import sys
from drgn import cast, container_of, Object
from drgn.helpers.linux.fs import path_lookup
from drgn.helpers.linux.list import list_for_each_entry
from drgn.helpers.linux.rbtree import rbtree_inorder_for_each_entry


# CHUNK_ALLOCATED is an alias for EXTENT_DIRTY
CHUNK_ALLOCATED = 1 << 0
BTRFS_DEV_EXTENT_KEY = 204


def get_fs_info(mountpoint):
    """Get btrfs_fs_info for a mountpoint."""
    path = path_lookup(prog, mountpoint)
    fs_info = cast("struct btrfs_fs_info *", path.mnt.mnt_sb.s_fs_info)
    return fs_info


def format_size(bytes_val):
    """Format bytes into human-readable size."""
    bytes_val = int(bytes_val)
    if bytes_val < 1024:
        return f"{bytes_val}B"
    elif bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f}K"
    elif bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.1f}M"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024):.1f}G"


def walk_extent_io_tree(tree):
    """Walk an extent_io_tree and yield all extent_states."""
    root = tree.state
    stack = []
    node = root.rb_node

    while stack or node:
        if node:
            stack.append(node)
            node = node.rb_left
        else:
            node = stack.pop()
            try:
                state = container_of(node, "struct extent_state", "rb_node")
                yield state
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
            node = node.rb_right


def get_chunk_allocated_ranges(device):
    """Get all CHUNK_ALLOCATED ranges for a device."""
    ranges = []
    for state in walk_extent_io_tree(device.alloc_state):
        bits = int(state.state)
        if bits & CHUNK_ALLOCATED:
            ranges.append((int(state.start), int(state.end) + 1))  # [start, end)
    return sorted(ranges)


def get_chunk_map_stripes(fs_info, devid):
    """Get all stripes for a device from chunk maps."""
    stripes = []

    # Walk the mapping_tree rb_tree
    for map in rbtree_inorder_for_each_entry(
        "struct btrfs_chunk_map",
        fs_info.mapping_tree,
        "rb_node"
    ):
        logical = int(map.start)
        chunk_len = int(map.chunk_len)
        stripe_size = int(map.stripe_size)
        num_stripes = int(map.num_stripes)
        chunk_type = int(map.type)

        for i in range(num_stripes):
            stripe = map.stripes[i]
            stripe_devid = int(stripe.dev.devid)
            if stripe_devid == devid:
                physical = int(stripe.physical)
                stripes.append({
                    'logical': logical,
                    'physical': physical,
                    'size': stripe_size,
                    'end': physical + stripe_size,
                    'stripe_idx': i,
                    'num_stripes': num_stripes,
                    'type': chunk_type,
                })

    return sorted(stripes, key=lambda x: x['physical'])


def walk_btree_leaves(root_node):
    """Walk a btrfs btree and yield all leaf nodes."""
    if not root_node:
        return

    level = int(root_node.header.read_once().level)
    if level == 0:
        yield root_node
        return

    # Internal node - recurse
    nritems = int(root_node.header.read_once().nritems)
    for i in range(nritems):
        # Get child block
        # Note: this is simplified and may need adjustment for your kernel
        try:
            child_bytenr = int(root_node.node.ptrs[i].blockptr)
            # We can't easily read arbitrary blocks in drgn without more infrastructure
            # So this is a placeholder - the actual implementation would need
            # to read the child node from disk or find it in cache
        except:
            pass

    yield root_node  # Fallback: yield current node


def get_dev_extents_from_commit_root(fs_info, devid):
    """
    Get dev extents from commit root for a specific device.
    This is what find_free_dev_extent() sees.

    Note: This walks the btree in memory which approximates what the
    commit root contains. For accurate results on a live system,
    you'd need to ensure no concurrent modifications.
    """
    extents = []

    dev_root = fs_info.dev_root
    if not dev_root:
        print("  Warning: dev_root is NULL")
        return extents

    # Get the commit root
    commit_root = dev_root.commit_root
    if not commit_root:
        print("  Warning: commit_root is NULL, using current root")
        commit_root = dev_root.node

    # Walk the tree looking for DEV_EXTENT items
    # Note: This is a simplified walk - a proper implementation would
    # do a full btree traversal, but that's complex in drgn
    #
    # For now, we'll walk the current root and note that commit_root
    # may differ during active transactions
    root_node = dev_root.node

    def walk_node(node, depth=0):
        """Recursively walk a btree node."""
        if not node or depth > 10:  # Safety limit
            return

        header = node.header.read_once()
        level = int(header.level)
        nritems = int(header.nritems)

        if level == 0:
            # Leaf node - scan items
            for i in range(nritems):
                try:
                    # Get key for this slot
                    # The item array is embedded in the extent_buffer
                    # Keys are at the beginning of the leaf
                    item = cast("struct btrfs_item *",
                               node.data.address_of_() + prog['BTRFS_ITEM_OFFSET'](i))

                    # Actually, let's try a different approach using btrfs_item_key_to_cpu equivalent
                    # This is kernel-version dependent, so we'll use a simpler heuristic
                except Exception as e:
                    pass

    # For now, use a simpler approach: scan transaction's dirty list
    # or just report that we need kernel instrumentation
    print("  Note: Commit root dev extent scan requires kernel instrumentation")
    print("  Using btrfs check or comparing with 'btrfs ins dump-tree -t dev'")

    return extents


def get_dev_extents_from_current_root(fs_info, devid):
    """
    Get dev extents from current tree using btree search.
    This shows what's currently in the tree (may differ from commit_root).
    """
    extents = []

    # This would require implementing a full btree walk in drgn
    # For now, suggest using btrfs inspect-internal dump-tree

    return extents


def ranges_overlap(r1_start, r1_end, r2_start, r2_end):
    """Check if two ranges [start, end) overlap."""
    return r1_start < r2_end and r2_start < r1_end


def get_devices(fs_info):
    """Get all devices from fs_info."""
    fs_devices = fs_info.fs_devices
    return list_for_each_entry(
        "struct btrfs_device",
        fs_devices.devices.address_of_(),
        "dev_list"
    )


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]
    print(f"Verifying CHUNK_ALLOCATED vs chunk maps for: {mountpoint}\n")

    try:
        fs_info = get_fs_info(mountpoint)
        print(f"fs_info @ {hex(fs_info.value_())}")
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    # Check transaction state
    try:
        running_trans = fs_info.running_transaction
        if running_trans:
            transid = int(running_trans.transid)
            print(f"Running transaction: {transid}")
        else:
            print("No running transaction")
    except:
        pass

    issues_found = False

    for device in get_devices(fs_info):
        devid = int(device.devid)
        print(f"\n{'='*80}")
        print(f"DEVICE {devid}")
        print(f"{'='*80}")

        # Get CHUNK_ALLOCATED ranges
        allocated_ranges = get_chunk_allocated_ranges(device)
        print(f"\n1. CHUNK_ALLOCATED bitmap ({len(allocated_ranges)} ranges):")
        for start, end in allocated_ranges:
            print(f"   [0x{start:012x}, 0x{end:012x}) = {format_size(end - start)}")

        # Get chunk map stripes
        stripes = get_chunk_map_stripes(fs_info, devid)
        print(f"\n2. Chunk map stripes ({len(stripes)} stripes):")
        for s in stripes:
            print(f"   logical=0x{s['logical']:012x} phys=[0x{s['physical']:012x}, 0x{s['end']:012x}) "
                  f"size={format_size(s['size'])} stripe={s['stripe_idx']}/{s['num_stripes']}")

        # Note about commit root
        print(f"\n3. Dev extents in commit_root:")
        print(f"   To see commit_root dev extents, run:")
        print(f"   btrfs inspect-internal dump-tree -t dev {mountpoint}")
        print(f"   And look for items with (devid DEV_EXTENT physical)")
        print(f"   Compare physical offsets with CHUNK_ALLOCATED ranges above.")

        # CHECK 1: Every stripe should be within CHUNK_ALLOCATED
        print(f"\n--- Check 1: Stripes covered by CHUNK_ALLOCATED ---")
        uncovered = []
        for s in stripes:
            covered = False
            for alloc_start, alloc_end in allocated_ranges:
                if alloc_start <= s['physical'] and s['end'] <= alloc_end:
                    covered = True
                    break
            if not covered:
                uncovered.append(s)

        if uncovered:
            for s in uncovered:
                print(f"  WARNING: Stripe at 0x{s['physical']:012x} NOT fully covered by CHUNK_ALLOCATED!")
                print(f"           logical=0x{s['logical']:012x} stripe {s['stripe_idx']}")
            issues_found = True
        else:
            print("  All stripes covered by CHUNK_ALLOCATED - OK")

        # CHECK 2: Look for overlapping stripes (the bug!)
        print(f"\n--- Check 2: Overlapping stripes ---")
        overlaps = []
        for i, s1 in enumerate(stripes):
            for j, s2 in enumerate(stripes):
                if i >= j:
                    continue
                if s1['logical'] == s2['logical']:
                    continue  # Same chunk, skip
                if ranges_overlap(s1['physical'], s1['end'], s2['physical'], s2['end']):
                    overlaps.append((s1, s2))

        if overlaps:
            print(f"  CRITICAL: Found {len(overlaps)} overlapping stripe pair(s)!")
            for s1, s2 in overlaps:
                print(f"    Chunk 0x{s1['logical']:012x} stripe {s1['stripe_idx']}: "
                      f"[0x{s1['physical']:012x}, 0x{s1['end']:012x})")
                print(f"    Chunk 0x{s2['logical']:012x} stripe {s2['stripe_idx']}: "
                      f"[0x{s2['physical']:012x}, 0x{s2['end']:012x})")
                overlap_start = max(s1['physical'], s2['physical'])
                overlap_end = min(s1['end'], s2['end'])
                print(f"    OVERLAP: [0x{overlap_start:012x}, 0x{overlap_end:012x}) = {format_size(overlap_end - overlap_start)}")
                print()
            issues_found = True
        else:
            print("  No overlapping stripes - OK")

        # CHECK 3: Look for stripes that would overlap with other CHUNK_ALLOCATED ranges
        # (This could indicate the multi-extent bug)
        print(f"\n--- Check 3: CHUNK_ALLOCATED gaps analysis ---")
        if len(allocated_ranges) > 1:
            print(f"  {len(allocated_ranges)} separate CHUNK_ALLOCATED extents found")
            print(f"  Gaps between them:")
            for i in range(len(allocated_ranges) - 1):
                curr_end = allocated_ranges[i][1]
                next_start = allocated_ranges[i + 1][0]
                if next_start > curr_end:
                    gap_size = next_start - curr_end
                    print(f"    [0x{curr_end:012x}, 0x{next_start:012x}) = {format_size(gap_size)}")
            print(f"\n  These gaps could cause issues if find_free_dev_extent() only")
            print(f"  checks the first CHUNK_ALLOCATED extent (REGULAR policy bug).")
        else:
            print("  Single contiguous CHUNK_ALLOCATED extent - OK")

    print(f"\n{'='*80}")
    print("DIAGNOSTIC COMMANDS")
    print(f"{'='*80}")
    print(f"To see commit_root dev extents (what find_free_dev_extent sees):")
    print(f"  btrfs inspect-internal dump-tree -t dev {mountpoint} | grep DEV_EXTENT")
    print()
    print(f"To compare with current tree:")
    print(f"  btrfs inspect-internal dump-tree -t dev {mountpoint}")
    print()

    print(f"\n{'='*80}")
    if issues_found:
        print("ISSUES FOUND - see warnings above")
    else:
        print("All checks passed - no issues found")
    print(f"{'='*80}")


if __name__ == '__main__':
    main()
