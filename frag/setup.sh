DEV=$1
MNT=$2

DIR=$MNT/enospc

sudo umount $DEV
sudo mkfs.btrfs -f $DEV
sudo mount $DEV $MNT
sudo chown $USER $MNT
mkdir $DIR
