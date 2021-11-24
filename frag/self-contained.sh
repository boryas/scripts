DEV=$1
MNT=$2
TIME=$3

BASE_DIR=$(dirname $(readlink -f $0))

$BASE_DIR/setup.sh $DEV $MNT
$BASE_DIR/frag.sh $DEV $MNT $TIME
