#!/usr/bin/env bash
# Minimal reproducer for btrfs writeback storm metadata stall
#
# Uses repository boilerplate. See standalone-minimal.sh for a
# self-contained version.
#
# Reproduces the preemptive reclaim feedback loop:
#   FLUSH_DELALLOC → COW → delayed refs → bytes_may_use ↑ → more FLUSH_DELALLOC
#
# Usage: $0 <dev> <mnt> [file_size_gb]

SCRIPT=$(readlink -f "$0")
DIR=$(dirname "$SCRIPT")
SH_ROOT=$(dirname "$DIR")
source "$SH_ROOT/btrfs.sh"

_basic_dev_mnt_usage $@

dev=$1
mnt=$2
file_size_gb=${3:-100}

workdir="$mnt/writeback-storm"
seed_file="$workdir/urandom"
target_file="$workdir/urandom.copy"
meminfo_log="/tmp/writeback-storm-meminfo.log"

MONITOR_PID=""
STALL_PID=""
BPFTRACE_PID=""

cleanup() {
	_log "Cleaning up..."
	[ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null || true
	[ -n "$STALL_PID" ] && kill "$STALL_PID" 2>/dev/null || true
	[ -n "$BPFTRACE_PID" ] && kill "$BPFTRACE_PID" 2>/dev/null || true
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# --- Tuning ---
_log "Applying VM dirty tunables..."
sysctl -w vm.dirty_background_ratio=60 >/dev/null
sysctl -w vm.dirty_ratio=80 >/dev/null
sysctl -w vm.dirty_writeback_centisecs=0 >/dev/null
sysctl -w vm.dirty_expire_centisecs=360000 >/dev/null

_log "Remounting with commit=9999999..."
mount -o remount,commit=9999999 "$mnt"

# --- Preparation ---
mkdir -p "$workdir"

if [ ! -f "$seed_file" ]; then
	_log "Generating 1G seed file from /dev/urandom..."
	head -c 1G /dev/urandom > "$seed_file"
	sync
fi

# --- Monitoring ---
_log "Starting meminfo monitor -> $meminfo_log"
: > "$meminfo_log"
(
	while true; do
		ts=$(date +%H:%M:%S)
		dirty=$(grep -i "^Dirty:" /proc/meminfo | awk '{print $2, $3}')
		writeback=$(grep -i "^Writeback:" /proc/meminfo | awk '{print $2, $3}')
		echo "$ts  Dirty: $dirty  Writeback: $writeback" | tee -a "$meminfo_log"
		sleep 5
	done
) &
MONITOR_PID=$!

# --- Stall detector ---
# Periodically attempt a trivial metadata op to detect stalls.
_log "Starting stall detector..."
(
	stall_dir="$workdir/stall-probe"
	mkdir -p "$stall_dir"
	i=0
	while true; do
		start_ns=$(date +%s%N)
		touch "$stall_dir/probe_$((i % 10))" 2>/dev/null || true
		end_ns=$(date +%s%N)
		dur_ms=$(( (end_ns - start_ns) / 1000000 ))
		if [ "$dur_ms" -gt 1000 ]; then
			echo "STALL: touch took ${dur_ms}ms at $(date +%H:%M:%S)"
		fi
		i=$((i + 1))
		sleep 2
	done
) &
STALL_PID=$!

# --- Optional bpftrace ---
FLUSH_BT="$DIR/../../../local/scripts/bt/flush_effectiveness.bt"
if [ ! -f "$FLUSH_BT" ]; then
	# Try alternate path inside VM
	FLUSH_BT="/work/src/scripts/bt/flush_effectiveness.bt"
fi
if [ -f "$FLUSH_BT" ] && command -v bpftrace >/dev/null 2>&1; then
	_log "Starting flush_effectiveness.bt..."
	bpftrace "$FLUSH_BT" > /tmp/flush_effectiveness.out 2>&1 &
	BPFTRACE_PID=$!
	sleep 2
	if ! kill -0 "$BPFTRACE_PID" 2>/dev/null; then
		_err "bpftrace failed to start (check /tmp/flush_effectiveness.out)"
		BPFTRACE_PID=""
	fi
else
	_log "bpftrace not available or flush_effectiveness.bt not found, skipping"
fi

# --- Workload ---
rm -f "$target_file"
_log "Starting writeback storm: writing ${file_size_gb}G to $target_file"
_log "Monitor PID: $MONITOR_PID, Stall PID: $STALL_PID"

for i in $(seq 1 "$file_size_gb"); do
	cat "$seed_file" >> "$target_file"
	_log "[writer] ${i}G / ${file_size_gb}G written"
done

_log "Write phase complete. Syncing..."
sync
_log "Sync complete."

# --- Collect results ---
echo ""
_log "=== Post-workload state ==="
grep -i -e "^Dirty:" -e "^Writeback:" /proc/meminfo

echo ""
_log "=== btrfs filesystem usage ==="
btrfs filesystem usage "$mnt" 2>/dev/null | head -15 || true

# Stop bpftrace to get summary
if [ -n "$BPFTRACE_PID" ] && kill -0 "$BPFTRACE_PID" 2>/dev/null; then
	kill -INT "$BPFTRACE_PID"
	wait "$BPFTRACE_PID" 2>/dev/null || true
	BPFTRACE_PID=""
	echo ""
	_log "=== Flush effectiveness summary ==="
	tail -100 /tmp/flush_effectiveness.out
fi

echo ""
_log "Meminfo log: $meminfo_log"
_log "Flush log:   /tmp/flush_effectiveness.out"
_log "Run reset.sh before next iteration."
