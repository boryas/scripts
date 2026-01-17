#!/usr/bin/env drgn
"""
Dump CHUNK_ALLOCATED bits from device alloc_state extent_io_trees.

This shows which physical address ranges are marked as pending allocation
(allocated in current transaction but dev_extents not yet committed).

Usage:
    drgn scripts/drgn/dump_chunk_allocated.py <mountpoint>

Example:
    drgn scripts/drgn/dump_chunk_allocated.py /mnt/btrfs
"""

import sys
from drgn import cast, container_of
from drgn.helpers.linux.fs import path_lookup
from drgn.helpers.linux.list import list_for_each_entry


# Extent state bits from extent-io-tree.h
# Note: These use ENUM_BIT() which starts at bit 0
EXTENT_DIRTY = 1 << 0
EXTENT_UPTODATE = 1 << 1
EXTENT_LOCKED = 1 << 2
EXTENT_DIO_LOCKED = 1 << 3
EXTENT_NEW = 1 << 4
EXTENT_DELALLOC = 1 << 5
EXTENT_DEFRAG = 1 << 6
EXTENT_BOUNDARY = 1 << 7
EXTENT_NODATASUM = 1 << 8
EXTENT_CLEAR_META_RESV = 1 << 9
EXTENT_NEED_WAIT = 1 << 10
EXTENT_NORESERVE = 1 << 11
EXTENT_QGROUP_RESERVED = 1 << 12
EXTENT_CLEAR_DATA_RESV = 1 << 13
EXTENT_DELALLOC_NEW = 1 << 14
EXTENT_ADD_INODE_BYTES = 1 << 15
EXTENT_CLEAR_ALL_BITS = 1 << 16
EXTENT_NOWAIT = 1 << 17

# CHUNK_ALLOCATED is an alias for EXTENT_DIRTY
CHUNK_ALLOCATED = EXTENT_DIRTY
CHUNK_TRIMMED = EXTENT_DEFRAG


def bits_to_str(bits):
    """Convert extent state bits to string representation."""
    parts = []
    if bits & CHUNK_ALLOCATED:
        parts.append("CHUNK_ALLOCATED")
    if bits & CHUNK_TRIMMED:
        parts.append("CHUNK_TRIMMED")
    # Add other bits if present (shouldn't be for alloc_state, but just in case)
    other_bits = bits & ~(CHUNK_ALLOCATED | CHUNK_TRIMMED)
    if other_bits:
        parts.append(f"OTHER(0x{other_bits:x})")
    return "|".join(parts) if parts else "NONE"


def get_fs_info(mountpoint):
    """Get btrfs_fs_info for a mountpoint."""
    path = path_lookup(prog, mountpoint)
    fs_info = cast("struct btrfs_fs_info *", path.mnt.mnt_sb.s_fs_info)
    return fs_info


def walk_extent_io_tree(tree):
    """Walk an extent_io_tree and yield all extent_states."""
    # The tree uses struct rb_root (not rb_root_cached)
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


def format_size(bytes_val):
    """Format bytes into human-readable size."""
    bytes_val = int(bytes_val)
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


def get_devices(fs_info):
    """Get all devices from fs_info."""
    fs_devices = fs_info.fs_devices
    return list_for_each_entry(
        "struct btrfs_device",
        fs_devices.devices.address_of_(),
        "dev_list"
    )


def dump_device_alloc_state(device):
    """Dump alloc_state for a single device."""
    devid = int(device.devid)
    alloc_state = device.alloc_state

    extents = []
    for state in walk_extent_io_tree(alloc_state):
        start = int(state.start)
        end = int(state.end)
        bits = int(state.state)
        length = end - start + 1
        extents.append({
            'start': start,
            'end': end,
            'length': length,
            'bits': bits,
            'bits_str': bits_to_str(bits),
        })

    return devid, extents


def print_device_extents(devid, extents):
    """Print extent states for a device."""
    print(f"\n--- Device {devid} ({len(extents)} extent states) ---")

    if not extents:
        print("  No extent states (alloc_state is empty)")
        return

    print(f"  {'Start':<18} {'End':<18} {'Length':<12} {'Bits'}")
    print(f"  {'-'*18} {'-'*18} {'-'*12} {'-'*30}")

    chunk_allocated_count = 0
    chunk_allocated_total = 0

    for ext in sorted(extents, key=lambda x: x['start']):
        print(f"  0x{ext['start']:016x} 0x{ext['end']:016x} "
              f"{format_size(ext['length']):<12} {ext['bits_str']}")

        if ext['bits'] & CHUNK_ALLOCATED:
            chunk_allocated_count += 1
            chunk_allocated_total += ext['length']

    print(f"\n  Summary: {chunk_allocated_count} CHUNK_ALLOCATED ranges, "
          f"total {format_size(chunk_allocated_total)}")


def find_gaps(extents):
    """Find gaps between CHUNK_ALLOCATED extents."""
    allocated = [e for e in extents if e['bits'] & CHUNK_ALLOCATED]
    if len(allocated) < 2:
        return []

    gaps = []
    sorted_extents = sorted(allocated, key=lambda x: x['start'])
    for i in range(len(sorted_extents) - 1):
        curr_end = sorted_extents[i]['end']
        next_start = sorted_extents[i + 1]['start']
        if next_start > curr_end + 1:
            gaps.append({
                'start': curr_end + 1,
                'end': next_start - 1,
                'length': next_start - curr_end - 1,
            })
    return gaps


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    print(f"Dumping CHUNK_ALLOCATED bits for: {mountpoint}\n")

    # Get fs_info
    try:
        fs_info = get_fs_info(mountpoint)
        print(f"fs_info @ {hex(fs_info.value_())}")
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    print("=" * 80)
    print("DEVICE ALLOC_STATE (CHUNK_ALLOCATED bitmap)")
    print("=" * 80)

    all_devices = []
    for device in get_devices(fs_info):
        devid, extents = dump_device_alloc_state(device)
        all_devices.append((devid, extents))
        print_device_extents(devid, extents)

        # Show gaps between CHUNK_ALLOCATED extents
        gaps = find_gaps(extents)
        if gaps:
            print(f"\n  Gaps between CHUNK_ALLOCATED extents:")
            for gap in gaps:
                print(f"    0x{gap['start']:016x} - 0x{gap['end']:016x} "
                      f"({format_size(gap['length'])})")

    print("\n" + "=" * 80)
    print("SUMMARY")
    print("=" * 80)

    for devid, extents in all_devices:
        allocated = [e for e in extents if e['bits'] & CHUNK_ALLOCATED]
        if allocated:
            total = sum(e['length'] for e in allocated)
            print(f"Device {devid}: {len(allocated)} CHUNK_ALLOCATED range(s), "
                  f"total {format_size(total)}")

            # Check for potential issues
            gaps = find_gaps(extents)
            if gaps:
                print(f"  WARNING: {len(gaps)} gap(s) between CHUNK_ALLOCATED extents!")
                print(f"  This could indicate non-adjacent pending allocations.")
        else:
            print(f"Device {devid}: No CHUNK_ALLOCATED extents")

    print()


if __name__ == '__main__':
    main()
