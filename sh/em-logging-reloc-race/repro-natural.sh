#!/bin/bash
# NATURAL partial-overlap-drop reproducer (NO force_* injection). Throws every
# real unwaited-partial-drop source at a continuously-fsync'd compressed file and
# lets the passive MINT/POISON probes name the winner via the drop stack:
#   - relocation (btrfs balance -> invalidate_extent_cache, no i_rwsem)
#   - DIO overlapping buffered dirty (invalidate_folio 7666 -> async TRUNCATED OE)
#   - buffered write + ftruncate churn
# log_delay is only a timing amplifier of the real log-window race.
set -u
DEV=${1:?dev}; MNT=${2:-/mnt/scratch}; SECS=${3:-120}; LOG_DELAY_MS=${4:-300}; FIXB=${5:-N}
P=/sys/module/btrfs/parameters; F="$MNT/target"
log(){ echo "[nat $(date +%T)] $*"; }
[ -d "$P" ] || { echo "no dbg params"; exit 1; }
for k in skip_cow_werr force_ioerr force_partial_drop; do echo N > "$P/dbg_repro_$k"; done
echo "$FIXB" > "$P/dbg_repro_fix_b"; echo 0 > "$P/dbg_repro_ino"; echo 0 > "$P/dbg_repro_log_delay_ms"
log "fix_b=$(cat $P/dbg_repro_fix_b) (all force_* OFF)"

umount "$MNT" 2>/dev/null
mkfs.btrfs -f -O ^no-holes "$DEV" >/dev/null || exit 1
mkdir -p "$MNT"; mount -o compress-force=zstd:3,commit=1 "$DEV" "$MNT" || exit 1
dd if=/dev/zero bs=1M count=400 2>/dev/null | tr '\0' A > "$F"; sync
INO=$(stat -c %i "$F"); log "ino=$INO"
echo "$INO" > "$P/dbg_repro_ino"; echo "$LOG_DELAY_MS" > "$P/dbg_repro_log_delay_ms"
dmesg -C 2>/dev/null || true

# relocation loop
( e=$((SECONDS+SECS)); while [ $SECONDS -lt $e ]; do btrfs balance start -d -m "$MNT" >/dev/null 2>&1; done ) & B=$!
# DIO-overlapping-buffered + buffered churn + ftruncate + fsync
python3 - "$F" "$SECS" <<'PY' &
import os,sys,time,random,threading
path,secs=sys.argv[1],int(sys.argv[2]); end=time.time()+secs
buf=(b'BCDE'*16384)
def buffered():
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try: os.pwrite(fd,buf,random.randrange(0,64)*65536)
        except OSError: pass
    os.close(fd)
def dio():   # O_DIRECT writes overlapping buffered dirty -> invalidate_folio TRUNCATED
    try: fd=os.open(path,os.O_RDWR|os.O_DIRECT)
    except OSError: return
    ab=os.O_DIRECT and bytearray(4096)
    mv=memoryview(bytearray(65536))
    while time.time()<end:
        try: os.pwrite(fd,mv,random.randrange(0,64)*65536)
        except OSError: pass
    os.close(fd)
def churn():  # write then truncate into it
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try:
            b=random.randrange(0,64)*65536; os.pwrite(fd,buf,b)
            os.ftruncate(fd,b+random.randrange(1,15)*4096+1234)
        except OSError: pass
    os.close(fd)
def fsyncer():
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try: os.pwrite(fd,buf[:random.randrange(1,16)*4096],random.randrange(0,64)*65536); os.fdatasync(fd)
        except OSError: pass
    os.close(fd)
ts=[threading.Thread(target=f) for f in (buffered,buffered,dio,dio,churn,fsyncer,fsyncer)]
for t in ts: t.start()
for t in ts: t.join()
PY
W=$!

hit=0; e=$((SECONDS+SECS+5))
while [ $SECONDS -lt $e ]; do dmesg 2>/dev/null | grep -q "POISON MINTED" && { hit=1; break; }; sleep 2; done
wait $W 2>/dev/null; kill $B 2>/dev/null; pkill -P $$ 2>/dev/null
echo "============================================================"
echo "fix_b=$FIXB DROP-saw-LOGGING=$(dmesg|grep -c 'DROP observed LOGGING') POISON_MINTED=$(dmesg|grep -c 'POISON MINTED')"
echo "--- any drop stacks that saw LOGGING (names the natural source) ---"
dmesg | grep -A16 "at fs/btrfs/extent_map.c.*btrfs_drop_extent_map_range" | grep -iE "WARNING|POISON|finish_one_ordered|invalidate_folio|invalidate_extent_cache|relocate|merge_reloc|btrfs_work_helper|Workqueue|Call Trace|ftruncate|__x64|iomap|dio" | head -24
umount "$MNT" 2>/dev/null