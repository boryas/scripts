#!/usr/bin/env bash
# Ultra-minimal writeback storm reproducer.
# Uses the root filesystem, no mkfs, no parallelism, no monitoring.
#
# Usage: baby.sh <size_gb>
# Reset: baby.sh reset
#
# Expects / to be btrfs with compress-force=zstd:3.

set -e

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
workdir="/writeback-storm"
seed_file="$workdir/urandom"
target_file="$workdir/urandom.copy"

do_run() {
	local size_gb=$1
	mkdir -p "$workdir"

	if [ ! -f "$seed_file" ]; then
		echo "[*] Generating 1G seed file..."
		head -c 1G /dev/urandom > "$seed_file"
		sync
	fi

	local start=$(date +%s)

	for i in $(seq 1 "$size_gb"); do
		cat "$seed_file" >> "$target_file"
		grep -i -e dirty -e writeback /proc/meminfo
	done
	sync

	local end=$(date +%s)
	echo "Elapsed wall time: $(( end - start ))"
}

case "${1:-}" in
	reset)
		$DIR/reset.sh / 10
		;;
	""|--help|-h)
		echo "usage: $0 <size_gb>    run workload"
		echo "       $0 reset        reset state between runs"
		exit 1
		;;
	*)
		do_run "$1"
		;;
esac
