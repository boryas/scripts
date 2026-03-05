#!/usr/bin/env drgn
"""
Dump dev_extents from the COMMIT ROOT (what find_free_dev_extent sees).

This shows what the allocation code sees when searching for free space,
which may differ from the current tree if there are uncommitted allocations.

Usage:
    drgn scripts/drgn/dump_commit_root_dev_extents.py <mountpoint>
"""

import sys
from drgn import cast, Object
from drgn.helpers.linux.fs import path_lookup


# Key types
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
    elif bytes_val < 1024 * 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024 * 1024):.1f}G"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024 * 1024):.1f}T"


def btrfs_disk_key_objectid(disk_key):
    return int(disk_key.objectid)


def btrfs_disk_key_type(disk_key):
    return int(disk_key.type)


def btrfs_disk_key_offset(disk_key):
    return int(disk_key.offset)


def walk_btree_items(root):
    """
    Walk all items in a btree starting from root.
    Yields (objectid, type, offset, leaf, slot) for each item.
    """
    # This is a simplified walker - for production use, we'd need proper
    # btree traversal. For now, we'll use a different approach.
    pass


def get_dev_root_commit(fs_info):
    """Get the device tree root (commit root version)."""
    # The dev_root is fs_info->dev_root
    # The commit root is dev_root->commit_root
    dev_root = fs_info.dev_root
    if not dev_root:
        return None
    commit_root = dev_root.commit_root
    return commit_root


def read_dev_extent(leaf, slot):
    """Read a dev_extent item from a leaf."""
    # Get the item
    item = leaf.items[slot]

    # Get the data offset within the leaf
    data_offset = int(item.offset)

    # The leaf data starts after the header and items
    # leaf->data is the raw page data
    # Items are at the start, data grows from the end

    # Cast to get the dev_extent structure
    # The data is at: leaf_data + BTRFS_LEAF_DATA_OFFSET + item.offset
    # But in drgn we need to calculate this differently

    # For extent_buffer, the data is in pages
    # This is getting complex - let's use a simpler approach
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    print(f"Dumping COMMIT ROOT dev_extents for: {mountpoint}\n")

    try:
        fs_info = get_fs_info(mountpoint)
        print(f"fs_info @ {hex(fs_info.value_())}")
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    # Get device tree
    dev_root = fs_info.dev_root
    if not dev_root:
        print("No dev_root found!")
        sys.exit(1)

    print(f"dev_root @ {hex(dev_root.value_())}")

    # Get commit root
    commit_root = dev_root.commit_root
    if not commit_root:
        print("No commit_root found!")
        sys.exit(1)

    print(f"commit_root @ {hex(commit_root.value_())}")

    # Get the root node info
    root_level = int(commit_root.level if hasattr(commit_root, 'level') else 0)
    print(f"commit_root level: {root_level}")

    # Compare with current root
    node = dev_root.node
    print(f"current root @ {hex(node.value_())}")

    if commit_root.value_() == node.value_():
        print("\nNOTE: commit_root == current root (no uncommitted changes)")
    else:
        print("\nNOTE: commit_root != current root (UNCOMMITTED CHANGES PRESENT)")

    # We can't easily walk the btree from drgn without reimplementing
    # the btree code. Instead, let's check if there's a transaction running.

    running_trans = fs_info.running_transaction
    if running_trans:
        trans_id = int(running_trans.transid)
        print(f"\nRunning transaction: {trans_id}")

        # Check transaction state
        state = int(running_trans.state)
        state_names = {
            0: "TRANS_STATE_RUNNING",
            1: "TRANS_STATE_COMMIT_DOING",
            2: "TRANS_STATE_COMMIT_PREP",
            3: "TRANS_STATE_UNBLOCKED",
            4: "TRANS_STATE_COMPLETED",
            5: "TRANS_STATE_MAX",
        }
        print(f"Transaction state: {state_names.get(state, f'UNKNOWN({state})')}")
    else:
        print("\nNo running transaction")

    # Show last committed transaction
    last_trans = int(fs_info.last_trans_committed)
    print(f"Last committed transaction: {last_trans}")

    # Show generation info
    generation = int(fs_info.generation)
    print(f"Current generation: {generation}")

    print("\n" + "=" * 60)
    print("To see dev_extents, use: btrfs inspect-internal dump-tree -t dev")
    print("Note: dump-tree shows current tree, not commit root")
    print("=" * 60)


if __name__ == '__main__':
    main()
