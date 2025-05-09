#!/usr/bin/env bash

# TODO
# make it an rcli
# incorporate wl-copy

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
SCRIPTS_ROOT=$(dirname $SH_ROOT)

source "$SH_ROOT/boilerplate"

if [ $# -ne 1 ]; then
	_usage_msg "patch-name"
fi

PATCH_DIR=~/fstest-results

_latest_patch() {
	local patch_name=$1
	local d="$PATCH_DIR/$patch_name"

	f=$(ls -t "$d" | head -1)
	echo "$d/$f"
}

patch_name=$1
shift

latest_for_next=$(_latest_patch "for-next")
latest=$(_latest_patch "$patch_name")
echo "diffing results between $latest_for_next and $latest"

diff <(grep Failures $latest_for_next | sort) <(grep Failures $latest | sort) | grep '>'
