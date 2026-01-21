#!/usr/bin/env drgn
"""
Detect the CHUNK_ALLOCATED gap bug condition.

This script looks for the exact condition that can cause the EEXIST bug:
- A large dev_extent hole (gap between stripes on a device)
- That hole contains non-contiguous CHUNK_ALLOCATED bitmap regions

When find_free_dev_extent() with REGULAR policy finds such a hole, it only
adjusts for the FIRST CHUNK_ALLOCATED extent but misses subsequent ones,
potentially allocating space that overlaps with a pending allocation.

Usage:
    drgn scripts/drgn/detect_allocation_gap_bug.py <mountpoint>

Exit codes:
    0    No problematic gaps detected
    1    Problematic gap(s) detected (or error)
"""

import sys
from drgn import cast, container_of
from drgn.helpers.linux.fs import path_lookup
from drgn.helpers.linux.list import list_for_each_entry
from drgn.helpers.linux.rbtree import rbtree_inorder_for_each_entry


# CHUNK_ALLOCATED is an alias for EXTENT_DIRTY
CHUNK_ALLOCATED = 1 << 0


def get_fs_info(mountpoint):
    """Get btrfs_fs_info for a mountpoint."""
    path = path_lookup(prog, mountpoint)
    fs_info = cast("struct btrfs_fs_info *", path.mnt.mnt_sb.s_fs_info)
    return fs_info


def format_size(bytes_val):
    """Format bytes into human-readable size."""
    bytes_val = int(bytes_val)
    if bytes_val < 0:
        return f"-{format_size(-bytes_val)}"
    if bytes_val < 1024:
        return f"{bytes_val}B"
    elif bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f}K"
    elif bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.1f}M"
    elif bytes_val < 1024 * 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024 * 1024):.1f}G"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024 * 1024):.1f}T"


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
            except Exception:
                pass
            node = node.rb_right


def get_chunk_allocated_ranges(device):
    """Get all CHUNK_ALLOCATED ranges for a device as list of (start, end)."""
    ranges = []
    for state in walk_extent_io_tree(device.alloc_state):
        bits = int(state.state)
        if bits & CHUNK_ALLOCATED:
            ranges.append((int(state.start), int(state.end) + 1))  # [start, end)
    return sorted(ranges)


def get_chunk_map_stripes(fs_info, devid):
    """Get all stripes for a device from chunk maps as list of (start, end)."""
    stripes = []

    for chunk_map in rbtree_inorder_for_each_entry(
        "struct btrfs_chunk_map",
        fs_info.mapping_tree,
        "rb_node"
    ):
        num_stripes = int(chunk_map.num_stripes)
        stripe_size = int(chunk_map.stripe_size)

        for i in range(num_stripes):
            stripe = chunk_map.stripes[i]
            stripe_devid = int(stripe.dev.devid)
            if stripe_devid == devid:
                physical = int(stripe.physical)
                stripes.append((physical, physical + stripe_size))

    return sorted(stripes)


def get_devices(fs_info):
    """Get all devices from fs_info."""
    fs_devices = fs_info.fs_devices
    return list_for_each_entry(
        "struct btrfs_device",
        fs_devices.devices.address_of_(),
        "dev_list"
    )


def find_holes_between_stripes(stripes):
    """Find gaps (holes) between sorted stripes. Returns list of (hole_start, hole_end)."""
    holes = []
    for i in range(len(stripes) - 1):
        curr_end = stripes[i][1]
        next_start = stripes[i + 1][0]
        if next_start > curr_end:
            holes.append((curr_end, next_start))
    return holes


def get_chunk_allocated_in_range(allocated_ranges, hole_start, hole_end):
    """Get CHUNK_ALLOCATED extents that fall within or overlap a hole."""
    in_hole = []
    for alloc_start, alloc_end in allocated_ranges:
        # Check if this allocated range overlaps with the hole
        if alloc_start < hole_end and alloc_end > hole_start:
            # Clip to hole boundaries for reporting
            clipped_start = max(alloc_start, hole_start)
            clipped_end = min(alloc_end, hole_end)
            in_hole.append((clipped_start, clipped_end, alloc_start, alloc_end))
    return in_hole


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    try:
        fs_info = get_fs_info(mountpoint)
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    issues_found = []

    for device in get_devices(fs_info):
        devid = int(device.devid)

        # Get current stripes from chunk maps
        stripes = get_chunk_map_stripes(fs_info, devid)
        if not stripes:
            continue

        # Get CHUNK_ALLOCATED ranges
        allocated_ranges = get_chunk_allocated_ranges(device)
        if not allocated_ranges:
            continue

        # Find holes between stripes
        holes = find_holes_between_stripes(stripes)

        # Check each hole for non-contiguous CHUNK_ALLOCATED regions
        for hole_start, hole_end in holes:
            allocs_in_hole = get_chunk_allocated_in_range(
                allocated_ranges, hole_start, hole_end
            )

            # The bug condition: more than one CHUNK_ALLOCATED extent in a hole
            if len(allocs_in_hole) > 1:
                issues_found.append({
                    'devid': devid,
                    'hole_start': hole_start,
                    'hole_end': hole_end,
                    'hole_size': hole_end - hole_start,
                    'allocs_in_hole': allocs_in_hole,
                })

    if issues_found:
        print("=" * 80)
        print("BUG CONDITION DETECTED: Non-contiguous CHUNK_ALLOCATED in dev_extent holes")
        print("=" * 80)
        print()
        print("This condition can cause find_free_dev_extent() with REGULAR policy to")
        print("only adjust for the first CHUNK_ALLOCATED extent, missing subsequent ones.")
        print()

        for issue in issues_found:
            print(f"Device {issue['devid']}:")
            print(f"  Hole: [0x{issue['hole_start']:012x}, 0x{issue['hole_end']:012x}) "
                  f"size={format_size(issue['hole_size'])}")
            print(f"  CHUNK_ALLOCATED extents in this hole ({len(issue['allocs_in_hole'])}):")
            for clipped_start, clipped_end, orig_start, orig_end in issue['allocs_in_hole']:
                if clipped_start == orig_start and clipped_end == orig_end:
                    print(f"    [0x{orig_start:012x}, 0x{orig_end:012x}) "
                          f"size={format_size(orig_end - orig_start)}")
                else:
                    print(f"    [0x{clipped_start:012x}, 0x{clipped_end:012x}) "
                          f"(from [0x{orig_start:012x}, 0x{orig_end:012x})) "
                          f"size={format_size(clipped_end - clipped_start)}")

            # Show the gaps between allocated regions in this hole
            allocs = sorted(issue['allocs_in_hole'], key=lambda x: x[0])
            print(f"  Gaps between CHUNK_ALLOCATED extents:")
            for i in range(len(allocs) - 1):
                gap_start = allocs[i][1]  # clipped_end
                gap_end = allocs[i + 1][0]  # next clipped_start
                if gap_end > gap_start:
                    print(f"    GAP: [0x{gap_start:012x}, 0x{gap_end:012x}) "
                          f"size={format_size(gap_end - gap_start)}")
                    print(f"    ^^^ find_free_dev_extent REGULAR policy may allocate here!")
            print()

        sys.exit(1)
    else:
        # Silent exit with 0 - no issues
        sys.exit(0)


if __name__ == '__main__':
    main()
