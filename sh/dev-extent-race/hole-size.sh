#!/usr/bin/env bash
# Bug: EEXIST when inserting dev extent during block group creation

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

if [ $# -lt 3 ]; then
	_err "usage: $SCRIPT <dev> <mnt> <duration_seconds>"
	_usage
fi

dev=$1
mnt=$2
