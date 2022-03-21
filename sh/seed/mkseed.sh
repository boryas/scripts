#!/bin/sh

del_loop() {
  local img=$1
  local loop=$(losetup -a | grep $img | cut -d: -f1)
  losetup -d $loop
  rm $img
}

mk_loop() {
  local img=$1
  dd if=/dev/zero of=$img bs=100M count=2
  losetup -f $img
  losetup -a | grep $img | cut -d: -f1
}

clean_loop() {
  local img=$1
  del_loop $img
  mk_loop $img
}

mnt=$1

seed_img=/tmp/seed.img
del_loop $seed_img
seed_dev=$(mk_loop $seed_img)
echo "seed_dev: " $seed_dev

sprout_img=/tmp/sprout.img
del_loop $sprout_img
sprout_dev=$(mk_loop $sprout_img)

mkfs.btrfs -f $seed_dev
btrfstune -S 1 $seed_dev
mount $seed_dev $mnt
btrfs device add $sprout_dev $mnt
mount -o remount,rw $mnt
