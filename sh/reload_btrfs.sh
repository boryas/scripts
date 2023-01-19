#!/usr/bin/env bash

dev=$1
mnt=$2
umount $dev
rmmod btrfs
modprobe btrfs
mount $dev $mnt
