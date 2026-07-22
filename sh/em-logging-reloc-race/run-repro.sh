#!/bin/bash
# One-command entry for the btrfs extent_map EXTENT_FLAG_LOGGING-split repro
# (f86f7a75 btrfs_drop_extent_map_range inversion -> freed em on modified_extents
# -> RCU stall in btrfs_log_inode).
#
# Run this INSIDE the test environment (the box or VM booted on the
# boris/em-logging-repro kernel), on a scratch btrfs device.
# Prereq: btrfs.ko loaded with /sys/module/btrfs/parameters/dbg_repro_* present.
#
# WARNING: mkfs's <dev> every run - use a SCRATCH device.
#
#   run-repro.sh <mode> [dev] [mnt] [secs] [delay_ms]
#
# modes:
#   proof     FORCED partial-drop (models the truncated-OE / relocation drop),
#             fix_b A/B. Proves the mechanism + validates Fix B on ANY arch
#             (incl x86). Expect POISON_MINTED: fix_b=N >0, fix_b=Y ==0. FAST.
#   truncate  NATURAL truncated-OE churn (sub-folio writes + non-aligned
#             ftruncate + fsync). Expected to fire on ARM/64K-subpage; ~silent
#             on x86 4K (folio == sector). No force_* knobs.
#   dio       NATURAL DIO-invalidate-buffered-dirty (non-compressed fs).
#   all       NATURAL combined (balance + dio + churn + fsync).
#   ioerror   FORCED error-path drop (full-remove leak variant), fix_b A/B.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MODE=${1:?usage: run-repro.sh <proof|truncate|dio|all|ioerror> [dev] [mnt] [secs] [delay_ms]}
DEV=${2:-/dev/vdb}; MNT=${3:-/mnt/scratch}; SECS=${4:-120}; DELAY=${5:-300}
P=/sys/module/btrfs/parameters
modprobe btrfs 2>/dev/null || true
if [ ! -e "$P/dbg_repro_fix_b" ]; then
	echo "ERROR: debug btrfs.ko not loaded ($P/dbg_repro_* missing)."
	echo "Build+boot the boris/em-logging-repro kernel first (see README.md)."
	exit 1
fi
echo "mode=$MODE dev=$DEV mnt=$MNT secs=$SECS delay_ms=$DELAY arch=$(uname -m) page=$(getconf PAGE_SIZE)"

forced() {  # $1 = repro-workload.sh mode (truncate|ioerror)
	for fb in N Y; do
		echo "================= $MODE  fix_b=$fb ================="
		echo "$fb" > "$P/dbg_repro_fix_b"
		bash "$HERE/repro-workload.sh" "$DEV" "$MNT" "$1" "$SECS" "$DELAY" >/tmp/rr.$fb.log 2>&1
		echo "  DROP_saw_LOGGING=$(dmesg | grep -c 'DROP observed LOGGING')  POISON_MINTED=$(dmesg | grep -c 'POISON MINTED')  (fix_b=$fb)"
		dmesg | grep -m1 -A12 "POISON MINTED" 2>/dev/null | grep -iE "POISON MINTED|finish_one_ordered|invalidate_folio|btrfs_drop_extent_map_range|Workqueue" | head -6
		dmesg -C >/dev/null 2>&1 || true
	done
}

natural() { # $1 = natural script taking (dev mnt secs delay fix_b)
	for fb in N Y; do
		echo "================= $MODE  fix_b=$fb ================="
		bash "$1" "$DEV" "$MNT" "$SECS" "$DELAY" "$fb"
	done
}

case "$MODE" in
	proof)    forced truncate ;;
	ioerror)  forced ioerror ;;
	truncate) natural "$HERE/repro-truncate.sh" ;;
	dio)      natural "$HERE/repro-dio.sh" ;;
	all)      natural "$HERE/repro-natural.sh" ;;
	*) echo "unknown mode: $MODE"; exit 1 ;;
esac
echo "=== done ($MODE) ==="
