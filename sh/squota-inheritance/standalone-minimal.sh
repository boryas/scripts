#!/usr/bin/env bash
# Standalone minimal reproducer for btrfs squota inheritance bug
# Bug: Level 1 qgroups retain metadata usage after all members are removed

set -e

if [ $# -ne 2 ]; then
	echo "usage: $0 <dev> <mnt>"
	exit 1
fi

dev=$1
mnt=$2

# Unmount if already mounted
findmnt "$dev" >/dev/null && umount "$dev"

# Create fresh btrfs with simple quotas
mkfs.btrfs -f "$dev" >/dev/null
mount -o noatime "$dev" "$mnt"
btrfs quota enable --simple "$mnt"

# Create 2-level qgroup hierarchy
btrfs qgroup create 2/100 "$mnt"  # Q2 (level 2)
btrfs qgroup create 1/100 "$mnt"  # Q11 (level 1)
btrfs qgroup assign 1/100 2/100 "$mnt"

# Create base subvolume and add to Q2
btrfs subvolume create "$mnt/base" >/dev/null
base_id=$(btrfs subvolume show "$mnt/base" | grep 'Subvolume ID:' | awk '{print $3}')
btrfs qgroup assign "0/$base_id" 2/100 "$mnt"

# Create intermediate snapshot and add to Q11
btrfs subvolume snapshot "$mnt/base" "$mnt/intermediate" >/dev/null
inter_id=$(btrfs subvolume show "$mnt/intermediate" | grep 'Subvolume ID:' | awk '{print $3}')
btrfs qgroup assign "0/$inter_id" 1/100 "$mnt"

# Create working snapshot with --inherit (auto-adds to Q11)
btrfs subvolume snapshot -i 1/100 "$mnt/intermediate" "$mnt/snap" >/dev/null
snap_id=$(btrfs subvolume show "$mnt/snap" | grep 'Subvolume ID:' | awk '{print $3}')

sync

# Delete working snapshot (should auto-remove from Q11)
btrfs subvolume delete "$mnt/snap" >/dev/null
btrfs subvolume sync "$mnt" "$snap_id"

# Delete intermediate and remove from Q11
btrfs qgroup remove "0/$inter_id" 1/100 "$mnt"
btrfs subvolume delete "$mnt/intermediate" >/dev/null
btrfs subvolume sync "$mnt" "$inter_id"

# Check for bug: Does Q11 have usage with no members?
echo "Checking for leaked usage in 1/100:"
btrfs qgroup show -pc "$mnt"

# Check if Q11 has leaked usage
child_col=$(btrfs qgroup show -pc "$mnt" 2>/dev/null | awk '$1 == "1/100" {print $5}')
usage=$(btrfs qgroup show --raw "$mnt" 2>/dev/null | awk '$1 == "1/100" {print $2}')

if [ -z "$child_col" ] || [ "$child_col" = "-" ]; then
	if [ -n "$usage" ] && [ "$usage" -gt 0 ]; then
		echo "BUG REPRODUCED: 1/100 has $usage bytes but no members!"
		exit 0
	fi
fi

echo "No bug found"
exit 1
