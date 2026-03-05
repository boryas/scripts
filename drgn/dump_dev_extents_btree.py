#!/usr/bin/env drgn
"""
Dump dev_extents from both commit root and current root of the device tree.

This shows:
1. What find_free_dev_extent sees (commit root)
2. What the current state is (current root)
3. Uncommitted changes (differences between the two)

Usage:
    drgn scripts/drgn/dump_dev_extents_btree.py <mountpoint>
"""

import sys
from drgn import cast, Object, container_of
from drgn.helpers.linux.fs import path_lookup

# Constants from btrfs
BTRFS_DEV_EXTENT_KEY = 204
BTRFS_HEADER_SIZE = 101  # sizeof(struct btrfs_header)

# Header field offsets
# csum[32] + fsid[16] + bytenr(8) + flags(8) + chunk_tree_uuid[16] + generation(8) + owner(8) + nritems(4) + level(1)
HEADER_NRITEMS_OFFSET = 96  # offset to nritems (u32)
HEADER_LEVEL_OFFSET = 100   # offset to level (u8)


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


def page_to_virt(page):
    """Convert a struct page pointer to virtual address."""
    try:
        # Method 1: Use page.virtual if available (some configs)
        if hasattr(page, 'virtual') and page.virtual:
            return int(page.virtual)
    except:
        pass

    try:
        # Method 2: Calculate from vmemmap
        # virt = (page - vmemmap_base) / sizeof(struct page) * PAGE_SIZE + PAGE_OFFSET
        vmemmap = prog['vmemmap_base'].value_()
        page_offset = prog['page_offset_base'].value_()
        page_size = prog.type('struct page').size
        pfn = (page.value_() - vmemmap) // page_size
        return pfn * 4096 + page_offset
    except:
        pass

    try:
        # Method 3: Direct phys_to_virt style
        # For x86_64 with direct mapping
        PAGE_OFFSET = 0xffff888000000000  # Common value for x86_64
        vmemmap = 0xffffea0000000000  # Common vmemmap base
        page_size = 64  # sizeof(struct page) on x86_64
        pfn = (page.value_() - vmemmap) // page_size
        return pfn * 4096 + PAGE_OFFSET
    except:
        pass

    return None


def read_extent_buffer_bytes(eb, start, length):
    """Read bytes from an extent_buffer that may span multiple pages."""
    try:
        # Modern btrfs has eb->addr for direct access (contiguous mapping)
        addr = eb.addr
        if addr:
            addr_val = int(addr)
            if addr_val != 0:
                data = prog.read(addr_val + start, length)
                return data
    except Exception:
        pass

    # Multi-page extent buffer - need to read from correct folio(s)
    try:
        result = bytearray()
        offset = start
        remaining = length
        PAGE_SIZE = 4096

        while remaining > 0:
            # Which folio/page contains this offset?
            page_idx = offset // PAGE_SIZE
            page_offset = offset % PAGE_SIZE

            # How much can we read from this page?
            bytes_in_page = min(remaining, PAGE_SIZE - page_offset)

            # Get the folio for this page
            folio = eb.folios[page_idx]
            if not folio:
                return None

            # Calculate virtual address for this folio
            vmemmap = 0xffffea0000000000
            page_offset_base = 0xffff888000000000
            page_struct_size = prog.type('struct page').size

            folio_addr = folio.value_()
            pfn = (folio_addr - vmemmap) // page_struct_size
            virt_addr = pfn * PAGE_SIZE + page_offset_base

            # Read from this page
            page_data = prog.read(virt_addr + page_offset, bytes_in_page)
            result.extend(page_data)

            offset += bytes_in_page
            remaining -= bytes_in_page

        return bytes(result)
    except Exception as e:
        pass

    return None


def get_eb_level(eb):
    """Get the level of an extent_buffer."""
    try:
        data = read_extent_buffer_bytes(eb, HEADER_LEVEL_OFFSET, 1)
        if data:
            return data[0]
    except Exception as e:
        print(f"DEBUG: get_eb_level error: {e}")
    return 0


def get_eb_nritems(eb):
    """Get the number of items in an extent_buffer."""
    try:
        data = read_extent_buffer_bytes(eb, HEADER_NRITEMS_OFFSET, 4)
        if data:
            return int.from_bytes(data, 'little')
    except Exception as e:
        print(f"DEBUG: get_eb_nritems error: {e}")
    return 0


def debug_eb(eb, name):
    """Debug print extent_buffer info."""
    print(f"DEBUG {name}:")
    print(f"  eb @ {hex(eb.value_())}")
    print(f"  eb->start = {hex(int(eb.start))}")
    print(f"  eb->len = {int(eb.len)}")

    # Check addr field
    try:
        addr = eb.addr
        if addr:
            print(f"  eb->addr = {hex(int(addr))}")
        else:
            print(f"  eb->addr = NULL")
    except Exception as e:
        print(f"  eb->addr: error {e}")

    # Check folio
    try:
        folio = eb.folios[0]
        if folio:
            print(f"  eb->folios[0] = {hex(folio.value_())}")
            # Check page_size
            page_size = prog.type('struct page').size
            print(f"  sizeof(struct page) = {page_size}")

            vmemmap = 0xffffea0000000000
            page_offset_base = 0xffff888000000000
            folio_addr = folio.value_()
            pfn = (folio_addr - vmemmap) // page_size
            virt_addr = pfn * 4096 + page_offset_base
            print(f"  calculated virt_addr = {hex(virt_addr)}")
        else:
            print(f"  eb->folios[0] = NULL")
    except Exception as e:
        print(f"  folio check error: {e}")

    # Try reading header bytes
    try:
        header_bytes = read_extent_buffer_bytes(eb, 0, 16)
        if header_bytes:
            print(f"  first 16 bytes: {header_bytes.hex()}")
        else:
            print(f"  first 16 bytes: FAILED TO READ")
    except Exception as e:
        print(f"  read error: {e}")

    # Read nritems and level directly
    try:
        nritems_bytes = read_extent_buffer_bytes(eb, HEADER_NRITEMS_OFFSET, 4)
        level_bytes = read_extent_buffer_bytes(eb, HEADER_LEVEL_OFFSET, 1)
        if nritems_bytes:
            print(f"  nritems raw bytes: {nritems_bytes.hex()} = {int.from_bytes(nritems_bytes, 'little')}")
        if level_bytes:
            print(f"  level raw bytes: {level_bytes.hex()} = {level_bytes[0]}")
    except Exception as e:
        print(f"  header field read error: {e}")


def get_item_key(eb, slot):
    """Get the key for item at slot."""
    # For leaf nodes, items start at BTRFS_HEADER_SIZE
    # struct btrfs_item is 25 bytes: key(17) + offset(4) + size(4)
    # struct btrfs_disk_key is 17 bytes: objectid(8) + type(1) + offset(8)

    item_offset = BTRFS_HEADER_SIZE + slot * 25
    data = read_extent_buffer_bytes(eb, item_offset, 17)
    if not data:
        return None

    objectid = int.from_bytes(data[0:8], 'little')
    key_type = data[8]
    offset = int.from_bytes(data[9:17], 'little')

    return (objectid, key_type, offset)


def get_item_data_offset_size(eb, slot):
    """Get the data offset and size for item at slot."""
    # Item is at BTRFS_HEADER_SIZE + slot * 25
    # struct btrfs_item: key(17) + offset(4) + size(4)
    item_offset = BTRFS_HEADER_SIZE + slot * 25
    data = read_extent_buffer_bytes(eb, item_offset + 17, 8)
    if not data:
        return None, None

    # offset is relative to BTRFS_HEADER_SIZE (start of leaf data area)
    data_offset = int.from_bytes(data[0:4], 'little')
    data_size = int.from_bytes(data[4:8], 'little')

    return data_offset, data_size


def get_dev_extent_data(eb, slot):
    """Get dev_extent data for item at slot."""
    # struct btrfs_dev_extent:
    #   chunk_tree: u64 (8)
    #   chunk_objectid: u64 (8)
    #   chunk_offset: u64 (8)
    #   length: u64 (8)
    #   chunk_tree_uuid: u8[16] (16)
    # Total: 48 bytes

    data_offset, data_size = get_item_data_offset_size(eb, slot)
    if data_offset is None:
        return None

    # Data offset is relative to BTRFS_HEADER_SIZE
    # So actual position in eb is: BTRFS_HEADER_SIZE + data_offset
    actual_offset = BTRFS_HEADER_SIZE + data_offset
    leaf_data = read_extent_buffer_bytes(eb, actual_offset, min(48, data_size))

    if not leaf_data or len(leaf_data) < 32:
        return None

    # Parse the dev_extent structure
    chunk_offset = int.from_bytes(leaf_data[16:24], 'little')
    length = int.from_bytes(leaf_data[24:32], 'little')

    return {
        'length': length,
        'chunk_offset': chunk_offset
    }


def get_key_ptr_blockptr(eb, slot):
    """Get blockptr for internal node at slot."""
    # struct btrfs_key_ptr is 33 bytes: key(17) + blockptr(8) + generation(8)
    ptr_offset = BTRFS_HEADER_SIZE + slot * 33 + 17
    data = read_extent_buffer_bytes(eb, ptr_offset, 8)
    if not data:
        return None
    return int.from_bytes(data, 'little')


def read_extent_buffer_by_bytenr(fs_info, bytenr):
    """Read an extent buffer by its bytenr (logical address)."""
    # This is complex in the kernel - extent buffers are cached
    # For now, try to find it in the buffer cache or read from disk
    # Actually, for commit_root, the extent_buffer should already be in memory

    # The simple approach: commit_root is already an extent_buffer pointer
    # We need to follow child pointers which point to bytenrs
    # The kernel has find_extent_buffer() but we can't call that from drgn

    # For this script, we'll only walk what's already in memory
    # which means we can only see the root node of commit_root
    return None


def walk_dev_tree_leaf(eb, dev_extents):
    """Extract dev_extents from a leaf node."""
    nritems = get_eb_nritems(eb)

    for slot in range(nritems):
        key = get_item_key(eb, slot)
        if not key:
            continue

        objectid, key_type, offset = key

        if key_type == BTRFS_DEV_EXTENT_KEY:
            devid = objectid
            physical = offset

            extent_data = get_dev_extent_data(eb, slot)
            if extent_data:
                dev_extents.append({
                    'devid': devid,
                    'physical': physical,
                    'length': extent_data['length'],
                    'chunk_offset': extent_data['chunk_offset']
                })


def walk_dev_tree_node(eb, dev_extents, visited, fs_info, depth=0):
    """Walk a btree node (internal or leaf) recursively."""
    if depth > 10:  # Prevent infinite recursion
        return

    eb_addr = eb.value_()
    if eb_addr in visited:
        return
    visited.add(eb_addr)

    level = get_eb_level(eb)
    nritems = get_eb_nritems(eb)

    if level == 0:
        # Leaf node
        walk_dev_tree_leaf(eb, dev_extents)
    else:
        # Internal node - we can't easily follow children without
        # access to the buffer cache. For now, we'll just note this.
        pass


def get_dev_extents_from_root(root_eb, fs_info):
    """Get all dev_extents from a root extent_buffer."""
    dev_extents = []
    visited = set()

    if not root_eb:
        return dev_extents

    level = get_eb_level(root_eb)

    if level == 0:
        # Single leaf - walk it
        walk_dev_tree_leaf(root_eb, dev_extents)
    else:
        # Internal node - we can only see what's in memory
        # The commit_root is guaranteed to be in memory, but children may not be
        # For a complete walk, we'd need to read from disk
        pass

    return dev_extents


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    print(f"Analyzing dev tree for: {mountpoint}\n")

    try:
        fs_info = get_fs_info(mountpoint)
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    # Get device tree
    dev_root = fs_info.dev_root
    if not dev_root:
        print("No dev_root found!")
        sys.exit(1)

    commit_root = dev_root.commit_root
    current_root = dev_root.node

    print(f"dev_root @ {hex(dev_root.value_())}")
    print(f"commit_root @ {hex(commit_root.value_())} (level={get_eb_level(commit_root)}, items={get_eb_nritems(commit_root)})")
    print(f"current_root @ {hex(current_root.value_())} (level={get_eb_level(current_root)}, items={get_eb_nritems(current_root)})")
    print()

    if commit_root.value_() == current_root.value_():
        print("commit_root == current_root (no uncommitted changes)")
    else:
        print("*** commit_root != current_root (UNCOMMITTED CHANGES) ***")
    print()

    # Transaction info
    running_trans = fs_info.running_transaction
    if running_trans:
        print(f"Running transaction: {int(running_trans.transid)}")
        state = int(running_trans.state)
        state_names = {
            0: "RUNNING", 1: "COMMIT_DOING", 2: "COMMIT_PREP",
            3: "UNBLOCKED", 4: "COMPLETED", 5: "MAX"
        }
        print(f"Transaction state: TRANS_STATE_{state_names.get(state, f'UNKNOWN({state})')}")
    print(f"Last committed transaction: {int(fs_info.last_trans_committed)}")
    print(f"Current generation: {int(fs_info.generation)}")
    print()

    # Get dev_extents from commit root (if it's a leaf)
    print("=" * 70)
    print("COMMIT ROOT DEV_EXTENTS (what find_free_dev_extent sees)")
    print("=" * 70)

    commit_level = get_eb_level(commit_root)
    if commit_level == 0:
        commit_extents = get_dev_extents_from_root(commit_root, fs_info)
        if commit_extents:
            # Group by devid
            by_devid = {}
            for ext in commit_extents:
                devid = ext['devid']
                if devid not in by_devid:
                    by_devid[devid] = []
                by_devid[devid].append(ext)

            for devid in sorted(by_devid.keys()):
                extents = sorted(by_devid[devid], key=lambda x: x['physical'])
                print(f"\nDevice {devid}:")
                prev_end = 0
                for ext in extents:
                    phys = ext['physical']
                    length = ext['length']
                    end = phys + length

                    # Show holes
                    if phys > prev_end:
                        hole_size = phys - prev_end
                        print(f"  [HOLE] 0x{prev_end:012x} - 0x{phys:012x} ({format_size(hole_size)})")

                    print(f"  0x{phys:012x} - 0x{end:012x} ({format_size(length)}) -> logical 0x{ext['chunk_offset']:x}")
                    prev_end = end
        else:
            print("(no dev_extents found or tree is multi-level)")
    else:
        print(f"(commit_root is level {commit_level}, cannot walk without disk access)")
        print("Multi-level btree - would need to read child nodes from disk")

    # Get dev_extents from current root
    print()
    print("=" * 70)
    print("CURRENT ROOT DEV_EXTENTS")
    print("=" * 70)

    current_level = get_eb_level(current_root)
    if current_level == 0:
        current_extents = get_dev_extents_from_root(current_root, fs_info)
        if current_extents:
            by_devid = {}
            for ext in current_extents:
                devid = ext['devid']
                if devid not in by_devid:
                    by_devid[devid] = []
                by_devid[devid].append(ext)

            for devid in sorted(by_devid.keys()):
                extents = sorted(by_devid[devid], key=lambda x: x['physical'])
                print(f"\nDevice {devid}:")
                prev_end = 0
                for ext in extents:
                    phys = ext['physical']
                    length = ext['length']
                    end = phys + length

                    if phys > prev_end:
                        hole_size = phys - prev_end
                        print(f"  [HOLE] 0x{prev_end:012x} - 0x{phys:012x} ({format_size(hole_size)})")

                    print(f"  0x{phys:012x} - 0x{end:012x} ({format_size(length)}) -> logical 0x{ext['chunk_offset']:x}")
                    prev_end = end
        else:
            print("(no dev_extents found or tree is multi-level)")
    else:
        print(f"(current_root is level {current_level}, cannot walk without disk access)")

    print()


if __name__ == '__main__':
    main()
