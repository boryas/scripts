#!/bin/bash
# Guest-side reproducer for the extent_map EXTENT_FLAG_LOGGING-split race.
# Runs a compressed overwrite+fdatasync loop (sets LOGGING on the file's ems),
# widens the fast-fsync log window via the btrfs.dbg_repro_* knobs, and drives a
# concurrent btrfs_drop_extent_map_range() from one of several sources. The MINT
# probe (WARN + "DROP observed LOGGING em" in dmesg) fires when a drop lands in
# the window and prints the DROPPER's stack -> identifies the trigger.
#
# Usage (in the guest):
#   repro-workload.sh <scratch-dev> <mnt> <mode> [secs] [log_delay_ms]
#   mode: balance | ioerror | eof | mix   (default: balance)
#
# Requires the boris/em-logging-repro btrfs.ko loaded.
set -u
DEV=${1:?scratch dev, e.g. /dev/vdb}
MNT=${2:-/mnt/scratch}
MODE=${3:-balance}
SECS=${4:-120}
LOG_DELAY_MS=${5:-100}
PARM=/sys/module/btrfs/parameters
F="$MNT/target"
WSIZE=4096

log() { echo "[repro $(date +%T)] $*"; }

command -v mkfs.btrfs >/dev/null || { echo "no mkfs.btrfs"; exit 1; }
[ -d "$PARM" ] || { echo "btrfs.ko without dbg_repro_* params not loaded"; exit 1; }

log "reset knobs"
echo 0 > "$PARM/dbg_repro_ino"
echo 0 > "$PARM/dbg_repro_log_delay_ms"
echo N > "$PARM/dbg_repro_skip_cow_werr"
echo N > "$PARM/dbg_repro_force_ioerr" 2>/dev/null || true
echo N > "$PARM/dbg_repro_force_partial_drop" 2>/dev/null || true
# fix_b left as-is by caller (0 = reproduce, 1 = validate fix)
log "dbg_repro_fix_b=$(cat $PARM/dbg_repro_fix_b)"

log "mkfs + mount ($DEV) compress-force=zstd"
umount "$MNT" 2>/dev/null
mkfs.btrfs -f -O ^no-holes "$DEV" >/dev/null || exit 1
mkdir -p "$MNT"
mount -o compress-force=zstd:3,commit=1 "$DEV" "$MNT" || exit 1

# Create a compressed file with many small extents (overwrite churn creates the
# partial-overlap splits the bug needs). ~256MB so a data block group exists.
log "seed target file"
dd if=/dev/zero bs=1M count=256 2>/dev/null | tr '\0' 'A' > "$F"
sync
INO=$(stat -c %i "$F")
log "target ino=$INO"
echo "$INO" > "$PARM/dbg_repro_ino"
echo "$LOG_DELAY_MS" > "$PARM/dbg_repro_log_delay_ms"

MARK="DROP observed LOGGING em"
dmesg -C 2>/dev/null || dmesg --clear 2>/dev/null || true

# ---- concurrent drop-source ----
start_dropper() {
  case "$MODE" in
    balance)
      ( end=$((SECONDS+SECS)); while [ $SECONDS -lt $end ]; do
          btrfs balance start -d -m "$MNT" >/dev/null 2>&1
        done ) & DROP_PID=$!
      log "dropper: btrfs balance loop (pid $DROP_PID) -> invalidate_extent_cache" ;;
    ioerror)
      # Force a realistic write IO error on the target inode's ordered extents
      # (kernel's own error path does the em drop) + defeat the COW_WRITE_ERROR
      # full-wait guard so the drop races the fast-fsync log window.
      echo Y > "$PARM/dbg_repro_skip_cow_werr"
      echo Y > "$PARM/dbg_repro_force_ioerr"
      log "dropper: force_ioerr(ino=$INO) + skip_cow_werr -> finish_one_ordered error-path drop"
      DROP_PID=0 ;;
    truncate)
      # Model the truncated-OE / relocation PARTIAL-overlap drop from ordered
      # completion (unguarded by COW_WRITE_ERROR, not waited by a fast fsync).
      # Needs >4K extents so the tail drop leaves a surviving head split.
      echo Y > "$PARM/dbg_repro_force_partial_drop"
      WSIZE=8192
      log "dropper: force_partial_drop(ino=$INO) tail-drop -> truncated-OE/reloc partial split"
      DROP_PID=0 ;;
    eof|mix)
      ( end=$((SECONDS+SECS)); i=0; while [ $SECONDS -lt $end ]; do
          # EOF-straddling appends -> truncated ordered extents; + truncate churn
          dd if=/dev/zero bs=3072 count=1 seek=$((i%4096)) of="$F" conv=notrunc 2>/dev/null
          truncate -s $(( (RANDOM%256+1) * 1048576 - 1234 )) "$F" 2>/dev/null
          i=$((i+1))
        done ) & DROP_PID=$!
      [ "$MODE" = mix ] && ( end=$((SECONDS+SECS)); while [ $SECONDS -lt $end ]; do
          btrfs balance start -d -m "$MNT" >/dev/null 2>&1; done ) &
      log "dropper: eof/truncate churn (pid $DROP_PID)$( [ "$MODE" = mix ] && echo ' + balance' )" ;;
    *) echo "unknown mode $MODE"; exit 1 ;;
  esac
}

start_dropper

# ---- writer: overlapping compressed overwrites + fdatasync (sets LOGGING) ----
log "writer+fsync loops for ${SECS}s (log_delay=${LOG_DELAY_MS}ms ino=$INO)"
python3 - "$F" "$SECS" "$WSIZE" <<'PY' &
import os,sys,time,random,threading
path,secs,wsize=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
end=time.time()+secs
buf=(b'BCDE'*(max(wsize,4)//4))[:wsize]  # wsize bytes, compressible
def writer():          # generate ordered extents whose completion drops
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try: os.pwrite(fd,buf,random.randrange(0,60)*wsize)
        except OSError: pass
    os.close(fd)
def fsyncer():         # hold the widened log window (sets LOGGING on modified ems)
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try:
            os.pwrite(fd,buf,random.randrange(0,60)*wsize)
            os.fdatasync(fd)
        except OSError: pass
    os.close(fd)
ts=[threading.Thread(target=writer) for _ in range(3)]
ts+=[threading.Thread(target=fsyncer) for _ in range(2)]
for t in ts: t.start()
for t in ts: t.join()
PY
WPID=$!

# ---- watch dmesg for the probe ----
hit=0
end=$((SECONDS+SECS+5))
while [ $SECONDS -lt $end ]; do
  if dmesg 2>/dev/null | grep -q "$MARK"; then hit=1; log "*** MINT PROBE FIRED ***"; break; fi
  sleep 2
done

wait $WPID 2>/dev/null
[ "${DROP_PID:-0}" != 0 ] && kill "$DROP_PID" 2>/dev/null
pkill -P $$ 2>/dev/null

echo "============================================================"
if [ $hit -eq 1 ]; then
  log "RESULT: reproduced. em dump(s) + dropper stack:"
  dmesg | grep "$MARK" | head -6
  echo "--- dropper call stack (the racing caller) ---"
  dmesg | grep -A34 "btrfs_drop_extent_map_range+0x" | grep -iE "WARNING|drop on LOGGING|Call Trace|btrfs_|finish_ordered|process_one_work|worker_thread|kthread|RIP:" | head -30
else
  log "RESULT: no MINT probe in ${SECS}s (mode=$MODE, delay=${LOG_DELAY_MS}ms). Try larger delay / mix / longer run."
fi
umount "$MNT" 2>/dev/null
