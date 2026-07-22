#!/bin/bash
# NATURAL truncated-OE via DIO-invalidates-buffered-dirty (no force_*).
# NON-compressed fs so O_DIRECT is real. A DIO write over a buffered dirty range
# with a pending OE -> btrfs_invalidate_folio() marks the OE BTRFS_ORDERED_TRUNCATED
# (inode.c:7666), whose async completion (finish_one_ordered truncated branch,
# skip_pinned=false, no i_rwsem) partial-drops the (unpinned) em. A concurrent
# fsync (log window widened by dbg_repro_log_delay_ms) has it LOGGING -> poison.
set -u
DEV=${1:?dev}; MNT=${2:-/mnt/scratch}; SECS=${3:-120}; LOG_DELAY_MS=${4:-300}; FIXB=${5:-N}
P=/sys/module/btrfs/parameters; F="$MNT/target"
log(){ echo "[dio $(date +%T)] $*"; }
[ -d "$P" ] || { echo "no dbg params"; exit 1; }
for k in skip_cow_werr force_ioerr force_partial_drop; do echo N > "$P/dbg_repro_$k"; done
echo "$FIXB" > "$P/dbg_repro_fix_b"; echo 0 > "$P/dbg_repro_ino"; echo 0 > "$P/dbg_repro_log_delay_ms"
log "fix_b=$(cat $P/dbg_repro_fix_b) (all force_* OFF; NON-compressed; real DIO)"

umount "$MNT" 2>/dev/null
mkfs.btrfs -f -O ^no-holes "$DEV" >/dev/null || exit 1
mkdir -p "$MNT"; mount -o commit=1 "$DEV" "$MNT" || exit 1   # NO compress-force
: > "$F"; INO=$(stat -c %i "$F"); log "ino=$INO"
echo "$INO" > "$P/dbg_repro_ino"; echo "$LOG_DELAY_MS" > "$P/dbg_repro_log_delay_ms"
dmesg -C 2>/dev/null || true

python3 - "$F" "$SECS" <<'PY' &
import os,sys,time,random,threading,mmap
path,secs=sys.argv[1],int(sys.argv[2]); end=time.time()+secs
BIG=1024*1024
buf=(b'BCDE'*16384)                       # 64K buffered payload
dbuf=mmap.mmap(-1, 65536); dbuf.write(b'X'*65536)  # page-aligned for O_DIRECT
def buffered():   # create dirty buffered OEs (pending IO)
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try: os.pwrite(fd,buf,random.randrange(0,64)*65536)
        except OSError: pass
    os.close(fd)
def dio():        # O_DIRECT overwrite overlapping the buffered dirty range
    try: fd=os.open(path,os.O_RDWR|os.O_DIRECT)
    except OSError: return
    while time.time()<end:
        try:
            off=random.randrange(0,64)*65536 + random.randrange(1,15)*4096  # inside a 64K region
            os.pwrite(fd, dbuf[:4096], off)
        except OSError: pass
    os.close(fd)
def fsyncer():
    fd=os.open(path,os.O_RDWR)
    while time.time()<end:
        try: os.pwrite(fd,buf[:random.randrange(1,16)*4096],random.randrange(0,64)*65536); os.fdatasync(fd)
        except OSError: pass
    os.close(fd)
ts=[threading.Thread(target=f) for f in (buffered,buffered,buffered,dio,dio,fsyncer,fsyncer)]
for t in ts: t.start()
for t in ts: t.join()
PY
W=$!
hit=0; e=$((SECONDS+SECS+5))
while [ $SECONDS -lt $e ]; do dmesg 2>/dev/null | grep -q "POISON MINTED" && { hit=1; break; }; sleep 2; done
wait $W 2>/dev/null; pkill -P $$ 2>/dev/null
echo "============================================================"
echo "fix_b=$FIXB DROP-saw-LOGGING=$(dmesg|grep -c 'DROP observed LOGGING') POISON_MINTED=$(dmesg|grep -c 'POISON MINTED')"
dmesg | grep -A16 "at fs/btrfs/extent_map.c.*btrfs_drop_extent_map_range" | grep -iE "WARNING|POISON|finish_one_ordered|invalidate_folio|btrfs_work_helper|Workqueue|Call Trace|iomap|dio|truncate" | head -20
umount "$MNT" 2>/dev/null