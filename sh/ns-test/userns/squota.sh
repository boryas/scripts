#!/usr/bin/env bash

MNT=$1

btrfs quota enable --simple $MNT
btrfs qgroup show $MNT
dd if=/dev/zero of=$MNT/foo bs=4k count=3
sync
btrfs qgroup show $MNT
