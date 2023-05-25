#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/boilerplate"
source "$SH_ROOT/btrfs"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2

_umount $mnt
$MKFS -f -m single -d single --nodesize 4096 $dev
mount $dev $mnt

NR_FILES=1000000
F=$mnt/foo

del_one() {
  f=$(find $mnt -type f | shuf -n 1)
  rm $f
}

non_empty() {
  find $mnt -type f | read
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
    $BTRFS inspect-internal logical-resolve $off $mnt 2>&1 | grep -v 'No such file'
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
