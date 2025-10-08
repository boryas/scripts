#!/usr/bin/env bash

K=$((1 << 10))
TK=$((10 * K))
HK=$((100 * K))
mnt=/mnt/lol
sv=$mnt/sv
f=$sv/foo

# disable error injection
echo 75 > /sys/fs/btrfs/$(findmnt $mnt -no UUID)/bg_reclaim_threshold

btrfs subvol delete $sv
btrfs subvol create $sv

echo "write file"
dd if=/dev/zero of=$f bs=64k count=$TK
#echo "fallocate file"
#fallocate -l $((65536 * TK)) $f
sync $f
echo "punch holes"
for i in $(seq $TK); do
	fallocate -l 8192 -o $((65536 * i - 4096)) $f --punch-hole
done
sync $f

echo "FIRST EM DUMP" > em.out
drgn dump-em.drgn >> em.out

echo "start bpftrace and enable error injection"
bpftrace em.bt &> bt.out &
bpftrace_pid=$!
sleep 1

# enable error injection
echo 99 > /sys/fs/btrfs/$(findmnt $mnt -no UUID)/bg_reclaim_threshold

echo "fail writes"
# these all fail
for i in $(seq $TK); do
	off=$(shuf -i 1-65536 -n1)
	sz=$(shuf -i 0-7 -n1)
	sz=$((sz * 8192))
	dd if=/dev/zero of=$f bs=1 seek=$((65536 * i + $off)) count=$sz &>/dev/null
done
sync $f

echo "SECOND EM DUMP" >> em.out
drgn dump-em.drgn >> em.out
pkill bpftrace
wait $bpftrace_pid
