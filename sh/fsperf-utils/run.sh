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
TESTS=$@

_do_one() {
	local label=$1
	local fsperf_cmd="./fsperf -n$N -p $label $TESTS"
	local cmd="cd /mnt/repos/fsperf; sudo $fsperf_cmd"

	echo "run fsperf $fsperf_cmd"
	ssh $VM "$cmd"
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
test_label="$REV""_$test_hash"
make -j$(nproc)
rcli vm cycle $VM
rcli vm ready $VM
_do_one "$test_label"

ssh $VM "cd /mnt/repos/fsperf; ./fsperf-compare $baseline_label $test_label"
