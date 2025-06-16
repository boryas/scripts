#!/usr/bin/env bash

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

if [ $# -lt 3 ]
then
	_usage_msg "usage: $SCRIPT <vm> <revision> <N>"
fi

VM=$1
REV=$2
N=$3

_do_one() {
	label=$1

	ssh $VM "cd /mnt/repos/fsperf; sudo ./fsperf -n$N -p $label"
}

cd ~/repos/linux/
git co for-next
baseline_hash=$(git log -1 --pretty=format:"%h")
baseline_label="baseline_$baseline_hash"
make -j$(nproc)
rcli vm cycle $VM
rcli vm ready $VM
_do_one "$baseline_label"

git co $REV
test_hash=$(git log -1 --pretty=format:"%h")
test_label="$REV_$test_hash"
make -j$(nproc)
rcli vm cycle $VM
rcli vm ready $VM
_do_one "$test_label"

ssh $VM "cd /mnt/repos/fsperf; ./fsperf-compare $baseline_label $test_label"
