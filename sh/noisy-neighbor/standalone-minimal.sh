#!/usr/bin/env bash
#
# Minimal reproducer for btrfs lock stalls caused by CPU starvation
# from global direct reclaim.
#
# Memory hog fills most of RAM with tmpfs data, forcing constant global
# direct reclaim. All tasks share a single CPU, so reclaim activity
# starves btrfs lock holders of CPU time, inflating lock hold duration.
#
# Usage: standalone-minimal.sh <dev> <mnt> [duration_sec]
# Run VM with moderate memory: vng ... --memory 2G --cpus 4

set -euo pipefail

dev=${1:?Usage: $0 <dev> <mnt> [duration_sec]}
mnt=${2:?Usage: $0 <dev> <mnt> [duration_sec]}
DURATION=${3:-120}

BIGFILE=$mnt/bigfile
BIGFILE_SZ=$((32 << 30))
FIO_INSTANCES=8
FIO_JOBS_PER=256
NR_VICTIM_JOBS=16

VICTIM_CPUS="0-$(($(nproc)-1))"
VILLAIN_CPUS="0-$(($(nproc)-1))"

cleanup() {
	echo "cleanup..."
	pkill -f fio 2>/dev/null || true
	jobs -p | xargs -r kill 2>/dev/null || true
	wait 2>/dev/null
	mountpoint -q "$mnt" && umount "$mnt"
}
trap cleanup EXIT

# protect ourselves from OOM
echo -1000 > /proc/$$/oom_score_adj

# filesystem
mountpoint -q "$mnt" && umount "$mnt"
if [ "${MKFS:-}" = 1 ] || ! blkid "$dev" | grep -q btrfs; then
	echo "mkfs.btrfs $dev"
	mkfs.btrfs -f -m single -d single "$dev" >/dev/null
fi
mount -o noatime,commit=1 "$dev" "$mnt"

# leave writeback defaults (dirty_ratio=20, dirty_writeback=500cs)
# commit=1 mount option already forces 1s transaction commits

# big files for villains to read — one per fio instance to avoid VFS contention
PER_FILE_SZ=$((BIGFILE_SZ / FIO_INSTANCES))
for i in $(seq "$FIO_INSTANCES"); do
	f="$mnt/bigfile.$i"
	if [ ! -f "$f" ]; then
		echo "creating file $i/${FIO_INSTANCES} (${PER_FILE_SZ} bytes)..."
		dd if=/dev/zero of="$f" bs=1M count=$((PER_FILE_SZ >> 20)) status=none
	fi
done
sync
echo "created $FIO_INSTANCES files, $((BIGFILE_SZ >> 20))MB total"


start_villains() {
	for i in $(seq "$FIO_INSTANCES"); do
		taskset -c "$VILLAIN_CPUS" fio \
			--filename="$mnt/bigfile.$i" \
			--ioengine=psync --direct=0 --bs=1M --rw=randread \
			--numjobs="$FIO_JOBS_PER" --size="$PER_FILE_SZ" \
			--time_based --runtime="$DURATION" \
			--group_reporting --name="villain-$i" \
			--output="/tmp/fio-$i.log" &
		disown
	done
}

start_victims() {
	# create victim directory with files for fio to write to
	mkdir -p "$mnt/victims"
	taskset -c "$VICTIM_CPUS" fio \
		--directory="$mnt/victims" \
		--ioengine=psync --direct=0 --bs=4k --rw=randwrite \
		--numjobs="$NR_VICTIM_JOBS" \
		--filesize=64k --nrfiles=8 \
		--time_based --runtime="$DURATION" \
		--group_reporting --name=victim \
		--lat_percentile=1 \
		--output=/tmp/fio-victims.log &
	disown
}

vmstat_poll() {
	local prev_scan=0 prev_steal=0
	while [ ! -f "$mnt/.done" ]; do
		local scan=$(awk '/pgscan_direct / {print $2}' /proc/vmstat)
		local steal=$(awk '/pgsteal_direct / {print $2}' /proc/vmstat)
		local d_scan=$((scan - prev_scan))
		local d_steal=$((steal - prev_steal))
		local mem_free=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
		local cpu_psi=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | sed 's/avg10=//')
		local mem_psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
		local nr_run=$(awk '/procs_running/{print $2}' /proc/stat)
		local nr_blocked=$(awk '/procs_blocked/{print $2}' /proc/stat)
		local loadavg=$(cut -d' ' -f1-3 /proc/loadavg)
		local commit_last=$(awk '/last_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
		local commit_max=$(awk '/max_commit_ms/{print $2}' /sys/fs/btrfs/*/commit_stats 2>/dev/null)
		echo "POLL: cpu_psi=${cpu_psi} mem_psi=${mem_psi} pgscan_d=+$d_scan pgsteal_d=+$d_steal free=${mem_free}MB run=${nr_run} blk=${nr_blocked} load=${loadavg} commit_last=${commit_last}ms commit_max=${commit_max}ms"
		prev_scan=$scan
		prev_steal=$steal
		sleep 5
	done
}

echo "=== vmstat before ==="
grep -E 'pgscan_direct|pgsteal_direct|pgscan_kswapd|pgsteal_kswapd' /proc/vmstat

echo "start $((FIO_INSTANCES * FIO_JOBS_PER)) villains (${FIO_INSTANCES}x fio, ${FIO_JOBS_PER} jobs each) on CPU $VILLAIN_CPUS"
start_villains

echo "start $NR_VICTIM_JOBS victims (fio randwrite) on CPU $VICTIM_CPUS"
start_victims

vmstat_poll &
VMSTAT_PID=$!

echo "running for ${DURATION}s (memory=$(free -h | awk '/Mem:/{print $2}'))..."
sleep "$DURATION"
touch "$mnt/.done"
sleep 3

kill $VMSTAT_PID 2>/dev/null; wait $VMSTAT_PID 2>/dev/null

echo ""
echo "=== CPU pressure (system) ==="
cat /proc/pressure/cpu 2>/dev/null || echo "(PSI not available)"
echo "=== memory pressure (system) ==="
cat /proc/pressure/memory
echo "=== commit stats ==="
cat "/sys/fs/btrfs/$(findmnt -no UUID "$dev")/commit_stats" 2>/dev/null || true
echo "=== vmstat after ==="
grep -E 'pgscan_direct|pgsteal_direct|pgscan_kswapd|pgsteal_kswapd' /proc/vmstat
echo "=== victim fio latency ==="
grep -A5 'lat (usec\|lat (msec' /tmp/fio-victims.log 2>/dev/null || true
echo "done"
