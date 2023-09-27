#!/usr/bin/env sh

_fail() {
    echo "FAILED!"
    exit 1
}

_cleanup() {
    umount /dev/tst/lol
}

trap _cleanup exit 0 1 15

# prep a btrfs with squot enabled
/home/vmuser/btrfs-progs/mkfs.btrfs -f -O squota /dev/tst/lol >/dev/null 2>&1
mount /dev/tst/lol /mnt/lol

# create a snapshot src
btrfs subv create /mnt/lol/src >/dev/null 2>&1
dd if=/dev/zero of=/mnt/lol/src/foo bs=1M count=3 >/dev/null 2>&1
sync

# run the demo that:
# creates qg 1/100
# sets the limit to 10MiB
# snapshots src to snap, using qg 1/100
echo "RUN SQUOTA-DEMO" | tee /dev/kmsg
./squota-demo || _fail
echo "SQUOTA-DEMO DONE" | tee /dev/kmsg
/home/vmuser/btrfs-progs/btrfs inspect-internal dump-tree /dev/tst/lol >/tmp/tree 2>&1

# limit is 10MiB, so write 6 to snap (OK)
dd if=/dev/zero of=/mnt/lol/snap/f bs=6M count=1 >/dev/null 2>&1 || _fail

# write 6 more to nested (FAIL)
dd if=/dev/zero of=/mnt/lol/snap/subv/f bs=6M count=1 >/dev/null 2>&1 && _fail
sync

# shouldn't be more than 10MiB!
btrfs qgroup show /mnt/lol
