#!/usr/bin/env bash

compact () {
	while (true)
	do 
		echo 1 > /proc/sys/vm/compact_memory
	done
}

mkdir -p /mnt/lol
mkfs.xfs -f /dev/nvme0n1
mount -o noatime /dev/nvme0n1 /mnt/lol

for x in $(seq 1 8)
do
	fallocate -l100m /mnt/lol/file$x
	./reader /mnt/lol/file$x &
done

compact &
wait
