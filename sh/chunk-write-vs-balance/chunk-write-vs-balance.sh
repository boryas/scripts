#!/bin/bash

RUNTIME=$1

do_fio() {
	btrfs subvol create /mnt/lol/small
	fio --name=prep --directory=/mnt/lol/small --filesize=128k --nrfiles=100 --rw=randwrite --fsync=32
	btrfs subvol delete /mnt/lol/small
}

fio_loop() {
	while (true); do
		do_fio >/dev/null 2>&1
	done
}

do_chunk_write() {
	# chunk-write does fallocate, write in chunks, fsync
	/home/vmuser/scripts/c/chunk-write /mnt/lol/chunked
	sha256sum /mnt/lol/chunked >> /home/vmuser/scripts/c/chunk-write-shas
	rm /mnt/lol/chunked
}

chunk_write_loop() {
	while (true); do
		do_chunk_write
	done
}

do_balance() {
	btrfs balance start -dusage=90 /mnt/lol
}

balance_loop() {
	while (true); do
		do_balance >/dev/null 2>&1
	done
}

umount /dev/tst/lol
mkfs.btrfs /dev/tst/lol -f >/dev/null 2>&1
mount /dev/tst/lol /mnt/lol

fio_loop&
sfpid=$!

chunk_write_loop&
cwpid=$!

balance_loop&
bpid=$!

echo "Loops launched, sleep $RUNTIME seconds"
sleep $RUNTIME
echo "Done sleeping, kill loops."

kill $sfpid
kill $cwpid
kill $bpid
wait
