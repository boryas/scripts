#!/usr/bin/env bash

umount /mnt/lol
mkfs.btrfs -f -m single -d single --nodesize 4096 /dev/vg0/lv0
mount /dev/vg0/lv0 /mnt/lol

NR_FILES=1000000
F=/mnt/lol/foo

del_one() {
  f=$(find /mnt/lol -type f | shuf -n 1)
  rm $f
}

non_empty() {
  find /mnt/lol -type f | read
}

setup() {
  #fallocate -l8k $F
  for i in $(seq $NR_FILES)
  do
    #cp --reflink=always $F $F.$i
    fallocate -l8k $F.$i
  done
  echo "done setup; sync"
  sync
  echo "done setup"
}

del_loop() {
  echo "start deleting files"
  while $(non_empty)
  do
    del_one
  done
  echo "done deleting"
}

ino_resolve_loop() {
  #off=$(sudo xfs_io -c fiemap $F | cut -d' ' -f3 | cut -d. -f1 | grep -v $F)
  #off=$(($off * 512))
  echo "resolve inodes ($off)"
  while $(non_empty)
  do
    off=$(shuf -i 0-10000000000 -n 1)
    btrfs inspect-internal logical-resolve $off /mnt/lol 2>&1 | grep -v 'No such file'
  done
  echo "done resolve inodes"
}

setup &
setup_pid=$!
sleep 5
ino_resolve_loop &
ino_resolve_loop &
ino_resolve_loop &
ino_resolve_loop &
ino_resolve_loop &
wait $setup_pid
del_loop &
wait
