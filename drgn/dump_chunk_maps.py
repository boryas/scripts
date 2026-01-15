#!/usr/bin/env drgn
"""
Dump btrfs chunk maps and dev extents to help identify physical address overlaps.

This script displays:
1. All chunk maps sorted by logical address
2. All dev extents (stripes) sorted by physical address per device

The pattern described in the email that causes EEXIST:
- Logical L: Single data chunk at physical P
- Logical L+1: Dup metadata chunk at physical P-1 (stripe 0), P (stripe 1)
The second stripe of the DUP overlaps with the data chunk at physical P.

Usage:
    drgn scripts/drgn/dump_chunk_maps.py <mountpoint>

Example:
    drgn scripts/drgn/dump_chunk_maps.py /mnt/btrfs
"""

import sys
from drgn import cast, container_of
from drgn.helpers.linux.fs import path_lookup


# Block group type flags
BTRFS_BLOCK_GROUP_DATA = 1 << 0
BTRFS_BLOCK_GROUP_SYSTEM = 1 << 1
BTRFS_BLOCK_GROUP_METADATA = 1 << 2
BTRFS_BLOCK_GROUP_RAID0 = 1 << 3
BTRFS_BLOCK_GROUP_RAID1 = 1 << 4
BTRFS_BLOCK_GROUP_DUP = 1 << 5
BTRFS_BLOCK_GROUP_RAID10 = 1 << 6
BTRFS_BLOCK_GROUP_RAID5 = 1 << 7
BTRFS_BLOCK_GROUP_RAID6 = 1 << 8
BTRFS_BLOCK_GROUP_RAID1C3 = 1 << 9
BTRFS_BLOCK_GROUP_RAID1C4 = 1 << 10


def get_fs_info(mountpoint):
    """Get btrfs_fs_info for a mountpoint."""
    path = path_lookup(prog, mountpoint)
    fs_info = cast("struct btrfs_fs_info *", path.mnt.mnt_sb.s_fs_info)
    return fs_info


def type_to_str(chunk_type):
    """Convert chunk type flags to string representation."""
    parts = []

    # Block group type
    if chunk_type & BTRFS_BLOCK_GROUP_DATA:
        parts.append("DATA")
    if chunk_type & BTRFS_BLOCK_GROUP_METADATA:
        parts.append("META")
    if chunk_type & BTRFS_BLOCK_GROUP_SYSTEM:
        parts.append("SYS")

    # Profile
    if chunk_type & BTRFS_BLOCK_GROUP_RAID0:
        parts.append("RAID0")
    elif chunk_type & BTRFS_BLOCK_GROUP_RAID1:
        parts.append("RAID1")
    elif chunk_type & BTRFS_BLOCK_GROUP_DUP:
        parts.append("DUP")
    elif chunk_type & BTRFS_BLOCK_GROUP_RAID10:
        parts.append("RAID10")
    elif chunk_type & BTRFS_BLOCK_GROUP_RAID5:
        parts.append("RAID5")
    elif chunk_type & BTRFS_BLOCK_GROUP_RAID6:
        parts.append("RAID6")
    elif chunk_type & BTRFS_BLOCK_GROUP_RAID1C3:
        parts.append("RAID1C3")
    elif chunk_type & BTRFS_BLOCK_GROUP_RAID1C4:
        parts.append("RAID1C4")
    else:
        parts.append("SINGLE")

    return "|".join(parts)


def walk_rbtree_cached(root_cached, member_name, type_name):
    """Walk an rb_root_cached tree and yield objects."""
    stack = []
    node = root_cached.rb_root.rb_node

    while stack or node:
        if node:
            stack.append(node)
            node = node.rb_left
        else:
            node = stack.pop()
            try:
                obj = container_of(node, type_name, member_name)
                yield obj
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
            node = node.rb_right


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


# ============================================================================
# Collection Functions
# ============================================================================

def collect_chunk_info(chunk_map):
    """Collect information about a single chunk map."""
    num_stripes = int(chunk_map.num_stripes)
    stripes = []
    for i in range(num_stripes):
        stripe = chunk_map.stripes[i]
        dev = stripe.dev
        devid = int(dev.devid) if dev else -1
        stripes.append({
            'stripe_idx': i,
            'devid': devid,
            'physical': int(stripe.physical),
        })

    return {
        'logical': int(chunk_map.start),
        'length': int(chunk_map.chunk_len),
        'stripe_size': int(chunk_map.stripe_size),
        'type': int(chunk_map.type),
        'type_str': type_to_str(int(chunk_map.type)),
        'num_stripes': num_stripes,
        'stripes': stripes,
    }


def collect_all_chunks(fs_info):
    """Collect all chunk maps from fs_info."""
    chunks = []
    for chunk_map in walk_rbtree_cached(fs_info.mapping_tree, 'rb_node',
                                         'struct btrfs_chunk_map'):
        try:
            chunks.append(collect_chunk_info(chunk_map))
        except Exception as e:
            print(f"Error collecting chunk: {e}", file=sys.stderr)
    return chunks


def build_dev_extents(chunks):
    """Build dev extent list from chunk data, grouped by device."""
    # Dict: devid -> list of (physical_start, physical_end, logical, type_str, stripe_idx)
    dev_extents = {}

    for chunk in chunks:
        for stripe in chunk['stripes']:
            devid = stripe['devid']
            if devid == -1:
                continue
            physical_start = stripe['physical']
            # For dev extents, the length is stripe_size (not chunk_len)
            physical_end = physical_start + chunk['stripe_size']
            extent_info = {
                'physical_start': physical_start,
                'physical_end': physical_end,
                'length': chunk['stripe_size'],
                'logical': chunk['logical'],
                'type_str': chunk['type_str'],
                'stripe_idx': stripe['stripe_idx'],
                'num_stripes': chunk['num_stripes'],
            }
            if devid not in dev_extents:
                dev_extents[devid] = []
            dev_extents[devid].append(extent_info)

    # Sort each device's extents by physical start
    for devid in dev_extents:
        dev_extents[devid].sort(key=lambda x: x['physical_start'])

    return dev_extents


def find_overlaps(dev_extents):
    """Find overlapping dev extents on each device."""
    overlaps = []
    for devid, extents in dev_extents.items():
        for i in range(len(extents) - 1):
            curr = extents[i]
            next_ext = extents[i + 1]
            if curr['physical_end'] > next_ext['physical_start']:
                overlaps.append({
                    'devid': devid,
                    'extent1': curr,
                    'extent2': next_ext,
                    'overlap_start': next_ext['physical_start'],
                    'overlap_end': min(curr['physical_end'], next_ext['physical_end']),
                })
    return overlaps


# ============================================================================
# Presentation Functions
# ============================================================================

def print_chunks(chunks):
    """Print all chunk maps sorted by logical address."""
    print("=" * 100)
    print("CHUNK MAPS (sorted by logical address)")
    print("=" * 100)
    print(f"{'Logical':<18} {'Length':<12} {'Type':<20} {'Stripes'}")
    print("-" * 100)

    for chunk in sorted(chunks, key=lambda x: x['logical']):
        stripe_info = ", ".join(
            f"dev={s['devid']} phys=0x{s['physical']:x}"
            for s in chunk['stripes']
        )
        print(f"0x{chunk['logical']:016x} {format_size(chunk['length']):<12} "
              f"{chunk['type_str']:<20} [{stripe_info}]")

    print()


def print_dev_extents(dev_extents):
    """Print dev extents grouped by device, sorted by physical address."""
    print("=" * 100)
    print("DEV EXTENTS (sorted by physical address per device)")
    print("=" * 100)

    for devid in sorted(dev_extents.keys()):
        extents = dev_extents[devid]
        print(f"\n--- Device {devid} ({len(extents)} extents) ---")
        print(f"{'Physical Start':<18} {'Physical End':<18} {'Length':<12} "
              f"{'Logical':<18} {'Type':<20} {'Stripe'}")
        print("-" * 100)

        for ext in extents:
            stripe_str = f"{ext['stripe_idx']}/{ext['num_stripes']}"
            print(f"0x{ext['physical_start']:016x} 0x{ext['physical_end']:016x} "
                  f"{format_size(ext['length']):<12} 0x{ext['logical']:016x} "
                  f"{ext['type_str']:<20} {stripe_str}")

    print()


def print_overlaps(overlaps):
    """Print any detected overlaps."""
    print("=" * 100)
    print("OVERLAP ANALYSIS")
    print("=" * 100)

    if not overlaps:
        print("No overlapping dev extents detected.")
    else:
        print(f"FOUND {len(overlaps)} OVERLAPPING DEV EXTENT(S)!\n")
        for overlap in overlaps:
            e1 = overlap['extent1']
            e2 = overlap['extent2']
            print(f"Device {overlap['devid']}:")
            print(f"  Extent 1: phys=0x{e1['physical_start']:x}-0x{e1['physical_end']:x} "
                  f"logical=0x{e1['logical']:x} type={e1['type_str']} "
                  f"stripe={e1['stripe_idx']}/{e1['num_stripes']-1}")
            print(f"  Extent 2: phys=0x{e2['physical_start']:x}-0x{e2['physical_end']:x} "
                  f"logical=0x{e2['logical']:x} type={e2['type_str']} "
                  f"stripe={e2['stripe_idx']}/{e2['num_stripes']-1}")
            print(f"  Overlap:  0x{overlap['overlap_start']:x}-0x{overlap['overlap_end']:x} "
                  f"({format_size(overlap['overlap_end'] - overlap['overlap_start'])})")
            print()

    print()


def print_summary(chunks, dev_extents):
    """Print summary statistics."""
    print("=" * 100)
    print("SUMMARY")
    print("=" * 100)
    print(f"Total chunks: {len(chunks)}")

    type_counts = {}
    for chunk in chunks:
        t = chunk['type_str']
        type_counts[t] = type_counts.get(t, 0) + 1
    for t, count in sorted(type_counts.items()):
        print(f"  {t}: {count}")

    print(f"Total devices: {len(dev_extents)}")
    for devid in sorted(dev_extents.keys()):
        print(f"  Device {devid}: {len(dev_extents[devid])} extents")

    print()


# ============================================================================
# Main
# ============================================================================

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    print(f"Analyzing btrfs filesystem at: {mountpoint}\n")

    # Get fs_info
    try:
        fs_info = get_fs_info(mountpoint)
        print(f"fs_info @ {hex(fs_info.value_())}")
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    # Collection phase
    chunks = collect_all_chunks(fs_info)
    dev_extents = build_dev_extents(chunks)
    overlaps = find_overlaps(dev_extents)

    # Presentation phase
    print_summary(chunks, dev_extents)
    print_chunks(chunks)
    print_dev_extents(dev_extents)
    print_overlaps(overlaps)

    if overlaps:
        print("WARNING: Overlapping dev extents detected! This may cause EEXIST errors.")
        sys.exit(1)


if __name__ == '__main__':
    main()
