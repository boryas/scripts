#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 1 ]; then
	echo "usage: try-parallel.sh <nr-dev>"
	exit -22;
fi

nr_dev=$1

set +e
sudo umount /dev/vg/lv0
set -e
sudo mkfs.btrfs -f /dev/vg/lv0
sudo mount /dev/vg/lv0 /mnt/lol
for i in $(seq $(($nr_dev - 1)))
do
	sudo btrfs device add -f /dev/vg/lv$i /mnt/lol
done

# ensure min bgs lol
echo "sleeping 30s to ensure min bgs"
for i in $(seq 30)
do
	echo -n "$i "
	sleep 1
done
echo "done"

sudo fio --alloc-size 262144 try-parallel.fio
