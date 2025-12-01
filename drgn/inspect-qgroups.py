#!/usr/bin/env drgn
"""
Inspect in-memory btrfs qgroup hierarchy for squota leak debugging.

Usage:
    drgn inspect-qgroups.py <mountpoint>

Example:
    drgn inspect-qgroups.py /tmp/btrfs-squota-test
"""

import sys
from drgn import Object, cast, container_of
from drgn.helpers.linux.fs import path_lookup
from drgn.helpers.linux.list import list_for_each_entry


def get_fs_info(mountpoint):
    """Get btrfs_fs_info for a mountpoint."""
    path = path_lookup(prog, mountpoint)
    fs_info = cast("struct btrfs_fs_info *", path.mnt.mnt_sb.s_fs_info)
    return fs_info


def format_size(bytes_val):
    """Format bytes into human-readable size."""
    if bytes_val < 0:
        return f"-{format_size(-bytes_val)}"
    if bytes_val < 1024:
        return f"{bytes_val}B"
    elif bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.2f}K"
    elif bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.2f}M"
    elif bytes_val < 1024 * 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024 * 1024):.2f}G"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024 * 1024):.2f}T"


def qgroupid_to_str(qgroupid):
    """Convert qgroupid to level/id string format."""
    level = qgroupid >> 48
    objid = qgroupid & ((1 << 48) - 1)
    return f"{level}/{objid}"


def walk_rbtree(root, member_name, type_name):
    """Walk an rb-tree and yield objects."""
    stack = []
    node = root.rb_node

    while stack or node:
        if node:
            stack.append(node)
            node = node.rb_left
        else:
            node = stack.pop()
            # container_of to get the structure containing this node
            try:
                obj = container_of(node, type_name, member_name)
                yield obj
            except Exception as e:
                print(f"Error getting container_of: {e}", file=sys.stderr)
            node = node.rb_right


def collect_qgroup_info(qgroup):
    """Collect information about a single qgroup.

    Returns dict with qgroup metadata and accounting info.
    """
    qgroupid = int(qgroup.qgroupid)
    qgroupid_str = qgroupid_to_str(qgroupid)

    # Get accounting info
    rfer = int(qgroup.rfer)
    excl = int(qgroup.excl)
    rfer_cmpr = int(qgroup.rfer_cmpr)
    excl_cmpr = int(qgroup.excl_cmpr)

    # Count members (children) - qgroup->members is list of qgroup_list entries
    try:
        members = list(list_for_each_entry('struct btrfs_qgroup_list',
                                           qgroup.members.address_of_(),
                                           'next_member'))
        num_members = len(members)
    except:
        num_members = -1

    # Count parents - qgroup->groups is list of qgroup_list entries
    try:
        parents = list(list_for_each_entry('struct btrfs_qgroup_list',
                                           qgroup.groups.address_of_(),
                                           'next_group'))
        num_parents = len(parents)
    except:
        num_parents = -1

    return {
        'qgroupid': qgroupid,
        'qgroupid_str': qgroupid_str,
        'rfer': rfer,
        'excl': excl,
        'rfer_cmpr': rfer_cmpr,
        'excl_cmpr': excl_cmpr,
        'num_members': num_members,
        'num_parents': num_parents,
    }


def analyze_qgroup(qgroup_info):
    """Analyze a qgroup for issues.

    Returns list of issue strings (empty if no issues).
    """
    issues = []

    # Extract level from qgroupid
    level = qgroup_info['qgroupid'] >> 48

    # Check for leaked usage only on level 1+ qgroups (parent qgroups)
    # Level 0 qgroups are subvolumes and can have usage without members
    if level > 0:
        if qgroup_info['num_members'] == 0 and (qgroup_info['rfer'] > 0 or qgroup_info['excl'] > 0) or qgroup_info['excl_cmpr'] > 0 or qgroup_info['rfer_cmpr'] > 0:
            issues.append("LEAKED")

    # Check for corrupted values (suspiciously large, likely negative)
    if qgroup_info['rfer'] > (1 << 60) or qgroup_info['excl'] > (1 << 60):  # > 1 EiB
        issues.append("CORRUPT")
    if qgroup_info['rfer_cmpr'] > (1 << 60) or qgroup_info['excl_cmpr'] > (1 << 60):  # > 1 EiB
        issues.append("CORRUPT")

    return issues


def collect_fs_info(mountpoint):
    """Collect filesystem-level qgroup information.

    Returns dict with fs_info, flags, and list of qgroup info dicts.
    """
    fs_info = get_fs_info(mountpoint)

    # Collect filesystem metadata
    qgroup_flags = int(fs_info.qgroup_flags)

    BTRFS_QGROUP_STATUS_FLAG_ON = 1 << 0
    BTRFS_QGROUP_STATUS_FLAG_SIMPLE = 1 << 3

    quotas_enabled = bool(qgroup_flags & BTRFS_QGROUP_STATUS_FLAG_ON)
    simple_quotas = bool(qgroup_flags & BTRFS_QGROUP_STATUS_FLAG_SIMPLE)

    # Collect all qgroups
    qgroup_tree = fs_info.qgroup_tree
    qgroups = []

    if qgroup_tree.rb_node:
        for qgroup in walk_rbtree(qgroup_tree, 'node', 'struct btrfs_qgroup'):
            try:
                qgroup_info = collect_qgroup_info(qgroup)
                qgroup_info['issues'] = analyze_qgroup(qgroup_info)
                qgroups.append(qgroup_info)
            except Exception as e:
                print(f"Error collecting qgroup: {e}", file=sys.stderr)
                continue

    return {
        'fs_info_addr': hex(fs_info.value_()),
        'qgroup_flags': qgroup_flags,
        'quotas_enabled': quotas_enabled,
        'simple_quotas': simple_quotas,
        'qgroups': qgroups,
    }


def print_fs_summary(fs_data):
    """Print filesystem-level summary."""
    print(f"fs_info address: {fs_data['fs_info_addr']}")
    print(f"qgroup_flags: {hex(fs_data['qgroup_flags'])} (binary: {bin(fs_data['qgroup_flags'])})")

    if not fs_data['quotas_enabled']:
        print("Quotas are not enabled on this filesystem")
        return False

    if fs_data['simple_quotas']:
        print("Simple quotas (squota) ENABLED ✓")
    else:
        print("Traditional quotas enabled (not squota)")

    print()
    return True


def print_qgroup_table(qgroups):
    """Print qgroup information as a table."""
    print(f"{'QgroupID':<15} {'Referenced':<12} {'Exclusive':<12} {'Referenced Compressed':<24} {'Exclusive Compressed':<24}{'Members':<8} {'Parents':<8} {'Status'}")
    print("-" * 128)

    for qg in qgroups:
        status_str = " ".join(qg['issues']) if qg['issues'] else "OK"
        print(f"{qg['qgroupid_str']:<15} "
              f"{format_size(qg['rfer']):<12} {format_size(qg['excl']):<12} "
              f"{format_size(qg['rfer_cmpr']):<24} "
              f"{format_size(qg['excl_cmpr']):<24} "
              f"{qg['num_members']:<8} {qg['num_parents']:<8} {status_str}")

    print()


def print_statistics(qgroups):
    """Print overall statistics."""
    total = len(qgroups)
    with_issues = [qg for qg in qgroups if qg['issues']]

    print("=" * 128)
    print(f"Total qgroups found: {total}")
    print(f"Qgroups with issues: {len(with_issues)}")

    return with_issues


def print_detailed_issues(qgroups_with_issues):
    """Print detailed report for qgroups with issues."""
    if not qgroups_with_issues:
        return

    print()
    print("DETAILED ISSUE REPORT:")
    print("-" * 80)

    for qg in qgroups_with_issues:
        print(f"Qgroup: {qg['qgroupid_str']}")
        print(f"  Referenced: {qg['rfer']} ({format_size(qg['rfer'])})")
        print(f"  Exclusive:  {qg['excl']} ({format_size(qg['excl'])})")
        print(f"  Members:    {qg['num_members']}")
        print(f"  Parents:    {qg['num_parents']}")
        print(f"  Issues:     {', '.join(qg['issues'])}")
        print()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    mountpoint = sys.argv[1]

    print(f"Inspecting qgroups for mountpoint: {mountpoint}")
    print("=" * 80)

    # Collection phase
    try:
        fs_data = collect_fs_info(mountpoint)
    except Exception as e:
        print(f"Error collecting filesystem info: {e}")
        sys.exit(1)

    # Presentation phase
    if not print_fs_summary(fs_data):
        sys.exit(1)

    if not fs_data['qgroups']:
        print("Qgroup tree is empty!")
        sys.exit(0)

    print_qgroup_table(fs_data['qgroups'])
    qgroups_with_issues = print_statistics(fs_data['qgroups'])
    print_detailed_issues(qgroups_with_issues)


if __name__ == '__main__':
    main()
