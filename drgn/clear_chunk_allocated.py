#!/usr/bin/env drgn
"""
Clear CHUNK_ALLOCATED bits for a specific physical range.

This simulates a chunk being removed within the same transaction,
creating a gap in the CHUNK_ALLOCATED bitmap while the commit root
still shows a larger hole.

WARNING: This is for testing only - it creates an inconsistent state!

Usage:
    drgn scripts/drgn/clear_chunk_allocated.py <mountpoint> <start_hex> <end_hex>

Example:
    drgn scripts/drgn/clear_chunk_allocated.py /mnt 0xe2500000 0x122500000
"""

import sys
from drgn import cast, Object
from drgn.helpers.linux.fs import path_lookup
from drgn.helpers.linux.list import list_for_each_entry


EXTENT_DIRTY = 1 << 0  # CHUNK_ALLOCATED
EXTENT_NOWAIT = 1 << 17


def get_fs_info(mountpoint):
    """Get btrfs_fs_info for a mountpoint."""
    path = path_lookup(prog, mountpoint)
    fs_info = cast("struct btrfs_fs_info *", path.mnt.mnt_sb.s_fs_info)
    return fs_info


def get_devices(fs_info):
    """Get all devices from fs_info."""
    fs_devices = fs_info.fs_devices
    return list_for_each_entry(
        "struct btrfs_device",
        fs_devices.devices.address_of_(),
        "dev_list"
    )


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]
    start = int(sys.argv[2], 16)
    end = int(sys.argv[3], 16)

    print(f"Clearing CHUNK_ALLOCATED for range 0x{start:x} - 0x{end:x}")
    print(f"Mountpoint: {mountpoint}")

    try:
        fs_info = get_fs_info(mountpoint)
    except Exception as e:
        print(f"Error getting fs_info: {e}")
        sys.exit(1)

    # Get the __clear_extent_bit function
    try:
        clear_extent_bit = prog.function("__clear_extent_bit")
        print(f"Found __clear_extent_bit @ {hex(clear_extent_bit.address)}")
    except LookupError:
        print("Could not find __clear_extent_bit function")
        print("NOTE: drgn cannot call kernel functions directly.")
        print("This script would need to be run as a kernel module or use ftrace.")
        sys.exit(1)

    # We can't actually call kernel functions from drgn
    # But we can show what would need to be done
    print()
    print("To clear CHUNK_ALLOCATED bits, you would need to call:")
    print("  __clear_extent_bit(&device->alloc_state, start, end-1,")
    print("                     CHUNK_ALLOCATED | EXTENT_NOWAIT, NULL, NULL)")
    print()
    print("This is what btrfs_remove_chunk_map() does when removing a chunk.")
    print()
    print("For testing, consider adding a debugfs or sysfs interface to the kernel")
    print("that allows clearing CHUNK_ALLOCATED for a specific range.")

    for device in get_devices(fs_info):
        devid = int(device.devid)
        alloc_state_addr = device.alloc_state.address_of_().value_()
        print(f"\nDevice {devid}:")
        print(f"  alloc_state @ 0x{alloc_state_addr:x}")
        print(f"  Would clear range: 0x{start:x} - 0x{end-1:x}")


if __name__ == '__main__':
    main()
