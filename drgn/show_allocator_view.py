#!/usr/bin/env drgn
"""
Show what find_free_dev_extent would see: holes in commit root vs CHUNK_ALLOCATED.

This script:
1. Walks the dev_extent items in commit root to find committed allocations
2. Compares with CHUNK_ALLOCATED bitmap to show pending allocations
3. Shows what holes are visible to the allocator

Usage:
    drgn scripts/drgn/show_allocator_view.py <mountpoint>
"""

import sys
from drgn import cast, Object, container_of
from drgn.helpers.linux.fs import path_lookup
from drgn.helpers.linux.list import list_for_each_entry


BTRFS_DEV_EXTENT_KEY = 204
EXTENT_DIRTY = 1 << 0  # CHUNK_ALLOCATED
SZ_1G = 1024 * 1024 * 1024


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


def get_devices(fs_info):
    """Get all devices from fs_info."""
    fs_devices = fs_info.fs_devices
    return list_for_each_entry(
        "struct btrfs_device",
        fs_devices.devices.address_of_(),
        "dev_list"
    )


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
    """Get all CHUNK_ALLOCATED ranges for a device."""
    alloc_state = device.alloc_state
    ranges = []

    for state in walk_extent_io_tree(alloc_state):
        start = int(state.start)
        end = int(state.end)
        bits = int(state.state)
        if bits & EXTENT_DIRTY:  # CHUNK_ALLOCATED
            ranges.append((start, end + 1))  # end is inclusive, make exclusive

    return sorted(ranges)


def get_chunk_map_physical_ranges(fs_info, devid):
    """Get physical ranges from in-memory chunk maps for a device."""
    ranges = []

    # Walk the mapping_tree
    root = fs_info.mapping_tree.rb_root
    stack = []
    node = root.rb_node

    while stack or node:
        if node:
            stack.append(node)
            node = node.rb_left
        else:
            node = stack.pop()
            try:
                chunk_map = container_of(node, "struct btrfs_chunk_map", "rb_node")
                num_stripes = int(chunk_map.num_stripes)
                stripe_size = int(chunk_map.stripe_size)

                for i in range(num_stripes):
                    stripe = chunk_map.stripes[i]
                    dev = stripe.dev
                    if dev and int(dev.devid) == devid:
                        phys = int(stripe.physical)
                        ranges.append((phys, phys + stripe_size))
            except Exception:
                pass
            node = node.rb_right

    return sorted(ranges)


def find_holes(allocated_ranges, device_size):
    """Find holes (free space) given allocated ranges."""
    holes = []
    prev_end = 0

    for start, end in sorted(allocated_ranges):
        if start > prev_end:
            holes.append((prev_end, start))
        prev_end = max(prev_end, end)

    if prev_end < device_size:
        holes.append((prev_end, device_size))

    return holes


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    print(f"Analyzing allocator view for: {mountpoint}\n")

    try:
        fs_info = get_fs_info(mountpoint)
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    # Transaction info
    running_trans = fs_info.running_transaction
    last_committed = int(fs_info.last_trans_committed)
    generation = int(fs_info.generation)

    print(f"Last committed transaction: {last_committed}")
    print(f"Current generation: {generation}")
    if running_trans:
        print(f"Running transaction: {int(running_trans.transid)}")
    print()

    # Check commit_root vs current root
    dev_root = fs_info.dev_root
    if dev_root:
        commit_root = dev_root.commit_root
        current_root = dev_root.node
        if commit_root.value_() != current_root.value_():
            print("*** UNCOMMITTED DEV TREE CHANGES PRESENT ***")
            print(f"    commit_root @ {hex(commit_root.value_())}")
            print(f"    current_root @ {hex(current_root.value_())}")
            print()

    for device in get_devices(fs_info):
        devid = int(device.devid)
        total_bytes = int(device.total_bytes)

        print("=" * 70)
        print(f"DEVICE {devid} (total: {format_size(total_bytes)})")
        print("=" * 70)

        # Get CHUNK_ALLOCATED ranges (what contains_pending_extent sees)
        chunk_allocated = get_chunk_allocated_ranges(device)
        print(f"\nCHUNK_ALLOCATED bitmap ({len(chunk_allocated)} ranges):")
        total_allocated = 0
        for start, end in chunk_allocated:
            length = end - start
            total_allocated += length
            print(f"  0x{start:012x} - 0x{end:012x} ({format_size(length)})")
        print(f"  Total: {format_size(total_allocated)}")

        # Get in-memory chunk map ranges
        chunk_map_ranges = get_chunk_map_physical_ranges(fs_info, devid)
        print(f"\nIn-memory chunk_map physical ranges ({len(chunk_map_ranges)} stripes):")
        for start, end in chunk_map_ranges:
            length = end - start
            print(f"  0x{start:012x} - 0x{end:012x} ({format_size(length)})")

        # Find holes visible to allocator (using CHUNK_ALLOCATED)
        # The allocator sees commit root but uses CHUNK_ALLOCATED to filter
        bitmap_holes = find_holes(chunk_allocated, total_bytes)
        print(f"\nHoles in CHUNK_ALLOCATED bitmap (truly free space):")
        for start, end in bitmap_holes:
            if end - start >= SZ_1G:  # Only show 1GB+ holes
                print(f"  0x{start:012x} - 0x{end:012x} ({format_size(end - start)}) *** LARGE HOLE ***")
            elif end - start >= 256 * 1024 * 1024:  # 256MB+
                print(f"  0x{start:012x} - 0x{end:012x} ({format_size(end - start)})")

        # Identify pending allocations (in chunk_map but would look like hole in commit root)
        # This is approximate - we don't have easy access to commit root dev_extents from drgn
        print(f"\nNOTE: Holes in commit root may be larger if there are pending allocations.")
        print(f"      Use the transaction info above to determine if pending allocations exist.")

    print()


if __name__ == '__main__':
    main()
