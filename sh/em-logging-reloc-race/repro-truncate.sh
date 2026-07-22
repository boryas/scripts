#!/bin/bash
# NATURAL truncated-OE reproducer (no force_* injection). Produces real
# BTRFS_ORDERED_TRUNCATED ordered extents via write + ftruncate-into-the-write,
# whose async completion (btrfs_finish_one_ordered truncated branch, no i_rwsem)
# partial-drops [truncated_len,end) of a still-full em. A concurrent fsync (with
# the log window widened by dbg_repro_log_delay_ms) has that em LOGGING -> the
# f86f7a75 inversion mints the poison. Passive probes (MINT + POISON detector)
# observe it; log_delay is only a timing amplifier of a real race window.
#
# Usage (guest): repro-truncate.sh <dev> <mnt> <secs> <log_delay_ms> [fix_b:N|Y]
set -u
DEV=${1:?dev}; MNT=${2:-/mnt/scratch}; SECS=${3:-90}; LOG_DELAY_MS=${4:-300}; FIXB=${5:-N}
PARM=/sys/module/btrfs/parameters
F="$MNT/target"
log(){ echo "[trunc $(date +%T)] $*"; }

[ -d "$PARM" ] || { echo "btrfs dbg params not present"; exit 1; }
# ALL forcing OFF - this is a natural repro. Only log_delay (timing amplifier).
echo 0 > "$PARM/dbg_repro_ino"
echo 0 > "$PARM/dbg_repro_log_delay_ms"
echo N > "$PARM/dbg_repro_skip_cow_werr"
echo N > "$PARM/dbg_repro_force_ioerr"
echo N > "$PARM/dbg_repro_force_partial_drop"
echo "$FIXB" > "$PARM/dbg_repro_fix_b"
log "fix_b=$(cat $PARM/dbg_repro_fix_b) (all force_* OFF; natural truncated OEs only)"

umount "$MNT" 2>/dev/null
mkfs.btrfs -f -O ^no-holes "$DEV" >/dev/null || exit 1
mkdir -p "$MNT"; mount -o compress-force=zstd:3,commit=1 "$DEV" "$MNT" || exit 1
: > "$F"; INO=$(stat -c %i "$F"); log "target ino=$INO"
echo "$INO" > "$PARM/dbg_repro_ino"
echo "$LOG_DELAY_MS" > "$PARM/dbg_repro_log_delay_ms"
dmesg -C 2>/dev/null || true

python3 - "$F" "$SECS" <<'PY' &
import os,sys,time,random,threading
path,secs=sys.argv[1],int(sys.argv[2])
end=time.time()+secs
buf=(b'BCDE'*16384)  # up to 64K compressible
# On 64K-page/4K-sector btrfs (subpage), sub-folio writes at 4K-aligned offsets
# combined with a NON-64K-aligned i_size make a folio straddle i_size with dirty
# beyond-i_size sectors -> writeback marks the OE BTRFS_ORDERED_TRUNCATED
# (extent_io.c:1848), whose async completion partial-drops the still-full em.
def churn():
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try:
            off=random.randrange(0,256)*4096              # 4K-aligned
            sz=random.randrange(1,16)*4096                # 4K..60K (sub-folio)
            os.pwrite(fd,buf[:sz],off)
            os.ftruncate(fd,random.randrange(1,1024)*4096+random.randrange(1,4095))  # non-aligned i_size
        except OSError: pass
    os.close(fd)
def fsyncer(): # set LOGGING on the ems + hold the widened log window
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try:
            os.pwrite(fd,buf[:random.randrange(1,16)*4096],random.randrange(0,256)*4096)
            os.fdatasync(fd)
        except OSError: pass
    os.close(fd)
ts=[threading.Thread(target=churn) for _ in range(4)]
ts+=[threading.Thread(target=fsyncer) for _ in range(2)]
for t in ts: t.start()
for t in ts: t.join()
PY
WPID=$!

hit=0; end=$((SECONDS+SECS+5))
while [ $SECONDS -lt $end ]; do
  dmesg 2>/dev/null | grep -q "POISON MINTED" && { hit=1; break; }
  sleep 2
done
wait $WPID 2>/dev/null; pkill -P $$ 2>/dev/null

echo "============================================================"
echo "fix_b=$FIXB  DROP-saw-LOGGING=$(dmesg|grep -c 'DROP observed LOGGING')  POISON_MINTED=$(dmesg|grep -c 'POISON MINTED')"
if [ $hit -eq 1 ]; then
  echo "--- NATURAL poison-mint WARN + drop stack (must be a truncated path, no force_*) ---"
  dmesg | grep -A20 "POISON MINTED" | grep -iE "POISON MINTED|WARNING|btrfs_drop_extent_map_range|finish_one_ordered|btrfs_invalidate_folio|truncate|btrfs_work_helper|Workqueue|Call Trace|worker_thread|__x64|ftruncate" | head -20
fi
umount "$MNT" 2>/dev/null
