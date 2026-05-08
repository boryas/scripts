#!/usr/bin/env drgn
"""
pipeline-monitor.py — Snapshot btrfs metadata reclaim pipeline state

Shows the four pools that drive preemptive reclaim action selection,
plus derived metrics to validate our hypotheses:

  1. delalloc_bytes / ordered_bytes (data pipeline)
  2. delayed_refs_rsv .size vs .reserved (ref funding gap)
  3. delayed_block_rsv .size vs .reserved
  4. bytes_may_use, bytes_pinned (space_info level)
  5. Full block_rsv breakdown including per-inode sums
  6. Rates of change between snapshots
  7. need_preemptive_reclaim emulation (trigger + branch)

Usage:
  sudo drgn pipeline-monitor.py [interval_sec] [count]
  sudo drgn pipeline-monitor.py 5 60    # every 5s for 5 minutes
  sudo drgn pipeline-monitor.py --json 5 60  # JSON output

Default: 5 second interval, runs until Ctrl-C.
"""

import json as json_mod
import sys
import time

from drgn import cast, container_of
from drgn.helpers.common import *
from drgn.helpers.linux import *

# --- Args ---
json_mode = False
args = list(sys.argv[1:])
if '--json' in args:
    json_mode = True
    args.remove('--json')

interval = int(args[0]) if len(args) > 0 else 5
max_count = int(args[1]) if len(args) > 1 else 0

# --- Locate btrfs structures ---
sb = path_lookup(prog, "/").mnt.mnt_sb
fi = cast("struct btrfs_fs_info *", sb.s_fs_info)

meta_si = None
data_si = None
for si in list_for_each_entry("struct btrfs_space_info",
                              fi.space_info.address_of_(), "list"):
    if si.flags & 0x4:  # BTRFS_BLOCK_GROUP_METADATA
        meta_si = si
    if si.flags & 0x1:  # BTRFS_BLOCK_GROUP_DATA
        data_si = si

if meta_si is None:
    print("ERROR: No metadata space_info found")
    sys.exit(1)

# --- VM dirty/writeback counters ---
NR_FILE_DIRTY = next(v for n, v in prog.type('enum node_stat_item').enumerators if n == 'NR_FILE_DIRTY')
NR_WRITEBACK = next(v for n, v in prog.type('enum node_stat_item').enumerators if n == 'NR_WRITEBACK')
vm_node_stat = prog['vm_node_stat']
PAGE_SIZE = 4096

def read_percpu_counter(counter):
    """Read a struct percpu_counter value."""
    return counter.count.value_()

def calc_available_free_space_approx():
    """Approximate calc_available_free_space(BTRFS_RESERVE_FLUSH_ALL)."""
    try:
        avail = fi.free_chunk_space.counter.value_()
    except AttributeError:
        avail = fi.free_chunk_space.value_()

    if data_si is not None:
        data_chunk_size = data_si.chunk_size.value_()
        try:
            total_rw = fi.fs_devices.total_rw_bytes.value_()
        except AttributeError:
            total_rw = 0
        ten_pct = total_rw * 10 // 100
        if ten_pct > 0 and data_chunk_size > ten_pct:
            data_chunk_size = ten_pct
        if data_chunk_size > 1 << 30:
            data_chunk_size = 1 << 30
    else:
        data_chunk_size = 1 << 30

    if avail <= data_chunk_size:
        return 0
    avail -= data_chunk_size

    # FLUSH_ALL -> >> 6
    avail >>= 6
    return avail

def sum_inode_rsvs():
    """Sum block_rsv.reserved, delayed_rsv.reserved, and outstanding_extents
    across all btrfs inodes.

    Iterates the superblock's inode list. This is O(n_inodes) but typically
    fast enough for a 5s monitor interval.
    """
    inode_blk_total = 0
    inode_del_total = 0
    inode_oe_total = 0
    inode_count = 0

    try:
        # Walk sb->s_inodes list
        for inode in list_for_each_entry("struct inode",
                                          sb.s_inodes.address_of_(),
                                          "i_sb_list"):
            bi = container_of(inode, "struct btrfs_inode", "vfs_inode")
            blk_rsv = bi.block_rsv.reserved.value_()
            del_rsv = bi.delayed_rsv.reserved.value_()
            oe = bi.outstanding_extents.value_()
            if blk_rsv > 0 or del_rsv > 0 or oe > 0:
                inode_blk_total += blk_rsv
                inode_del_total += del_rsv
                inode_oe_total += oe
                inode_count += 1
    except Exception:
        # If iteration fails, return -1 to signal unavailable
        return -1, -1, -1, -1

    return inode_blk_total, inode_del_total, inode_oe_total, inode_count

def emulate_need_preemptive_reclaim(s):
    """Emulate need_preemptive_reclaim logic from space-info.c."""
    global_rsv_size = s['global_rsv_reserved']
    reclaim_size = s['reclaim_size']

    if reclaim_size:
        return (False, 'tickets', 0, 0)

    thresh_90 = s['total_bytes'] * 90 // 100
    if (s['bytes_used'] + s['bytes_reserved'] + global_rsv_size) >= thresh_90:
        return (False, 'full', 0, 0)

    used1 = s['bytes_may_use'] + s['bytes_pinned']
    if global_rsv_size >= used1:
        return (False, 'global>=used', 0, 0)

    if used1 - global_rsv_size <= (128 << 20):
        return (False, '<128M', 0, 0)

    avail = calc_available_free_space_approx()
    used_for_thresh = (s['bytes_used'] + s['bytes_reserved'] +
                       s['bytes_readonly'] + global_rsv_size)
    if used_for_thresh < s['total_bytes']:
        thresh = avail + (s['total_bytes'] - used_for_thresh)
    else:
        thresh = avail
    thresh >>= s['clamp']

    ordered = s['ordered_bytes'] >> 1
    delalloc = s['delalloc_bytes']

    used = s['bytes_pinned']
    if ordered >= delalloc:
        used += s['delrefs_rsv_reserved'] + s['delblock_rsv_reserved']
        branch = 'ord>=del'
    else:
        used += s['bytes_may_use'] - global_rsv_size
        branch = 'del>ord'

    triggered = used >= thresh
    return (triggered, branch, thresh / (1024*1024), used / (1024*1024))

def get_snapshot():
    """Capture a point-in-time snapshot of pipeline state."""
    s = {}

    # Space info level
    s['bytes_may_use'] = meta_si.bytes_may_use.value_()
    s['bytes_pinned'] = meta_si.bytes_pinned.value_()
    s['bytes_used'] = meta_si.bytes_used.value_()
    s['bytes_reserved'] = meta_si.bytes_reserved.value_()
    s['bytes_readonly'] = meta_si.bytes_readonly.value_()
    s['total_bytes'] = meta_si.total_bytes.value_()
    s['clamp'] = meta_si.clamp.value_()
    s['reclaim_size'] = meta_si.reclaim_size.value_()

    # Global RSVs (all on fs_info)
    s['global_rsv_size'] = fi.global_block_rsv.size.value_()
    s['global_rsv_reserved'] = fi.global_block_rsv.reserved.value_()

    s['delrefs_rsv_size'] = fi.delayed_refs_rsv.size.value_()
    s['delrefs_rsv_reserved'] = fi.delayed_refs_rsv.reserved.value_()

    s['delblock_rsv_size'] = fi.delayed_block_rsv.size.value_()
    s['delblock_rsv_reserved'] = fi.delayed_block_rsv.reserved.value_()

    s['trans_rsv_size'] = fi.trans_block_rsv.size.value_()
    s['trans_rsv_reserved'] = fi.trans_block_rsv.reserved.value_()

    s['chunk_rsv_size'] = fi.chunk_block_rsv.size.value_()
    s['chunk_rsv_reserved'] = fi.chunk_block_rsv.reserved.value_()

    s['treelog_rsv_size'] = fi.treelog_rsv.size.value_()
    s['treelog_rsv_reserved'] = fi.treelog_rsv.reserved.value_()

    # Per-inode RSV totals
    inode_blk, inode_del, inode_oe, inode_cnt = sum_inode_rsvs()
    s['inode_blk_reserved'] = inode_blk
    s['inode_del_reserved'] = inode_del
    s['inode_oe_total'] = inode_oe
    s['inode_rsv_count'] = inode_cnt

    # Data pipeline counters (percpu)
    s['delalloc_bytes'] = read_percpu_counter(fi.delalloc_bytes)
    s['ordered_bytes'] = read_percpu_counter(fi.ordered_bytes)

    # VM dirty/writeback (pages -> bytes)
    s['dirty_bytes'] = vm_node_stat[NR_FILE_DIRTY].counter.value_() * PAGE_SIZE
    s['writeback_bytes'] = vm_node_stat[NR_WRITEBACK].counter.value_() * PAGE_SIZE

    # Delayed refs state
    trans_ptr = fi.running_transaction
    if trans_ptr:
        t = trans_ptr[0]
        s['num_heads'] = t.delayed_refs.num_heads.value_()
        s['num_heads_ready'] = t.delayed_refs.num_heads_ready.value_()
        s['transid'] = t.transid.value_()
    else:
        s['num_heads'] = 0
        s['num_heads_ready'] = 0
        s['transid'] = 0

    # Compute residuals
    global_reserved = (s['global_rsv_reserved'] +
                       s['delrefs_rsv_reserved'] +
                       s['delblock_rsv_reserved'] +
                       s['trans_rsv_reserved'] +
                       s['chunk_rsv_reserved'] +
                       s['treelog_rsv_reserved'])
    s['global_named_reserved'] = global_reserved

    if inode_blk >= 0:
        all_named = global_reserved + inode_blk + inode_del
        s['residual'] = max(0, s['bytes_may_use'] - all_named)
    else:
        s['residual'] = max(0, s['bytes_may_use'] - global_reserved)

    # Action selection
    delalloc_size = max(0, s['bytes_may_use'] - global_reserved)
    block_rsv_size = global_reserved - s['global_rsv_reserved']
    pinned = s['bytes_pinned']
    delblock = s['delblock_rsv_reserved']
    delrefs = s['delrefs_rsv_reserved']

    if delalloc_size > block_rsv_size:
        s['would_pick'] = 'DELALLOC'
    elif pinned > delblock + delrefs:
        s['would_pick'] = 'COMMIT'
    elif delblock > delrefs:
        s['would_pick'] = 'DEL_ITEMS'
    else:
        s['would_pick'] = 'DEL_REFS'

    # Emulate need_preemptive_reclaim
    triggered, branch, thresh_mb, used_mb = emulate_need_preemptive_reclaim(s)
    s['npr_trigger'] = triggered
    s['npr_branch'] = branch
    s['npr_thresh'] = thresh_mb
    s['npr_used'] = used_mb

    return s

def mb(v):
    return v / (1024 * 1024)

def gb(v):
    return v / (1024 * 1024 * 1024)

# --- Table output ---
def print_header():
    print(f"{'TIME':>8s}  "
          f"{'dirty':>7s} {'wb':>7s} "
          f"{'may_use':>9s} {'pinned':>8s} "
          f"{'delalloc':>9s} {'ordered':>9s} "
          f"{'refs.sz':>8s} {'refs.rv':>8s} {'items.rv':>8s} "
          f"{'i_blk':>8s} {'i_del':>8s} {'i_oe':>7s} {'i_cnt':>5s} "
          f"{'chunk':>6s} {'trlog':>6s} {'trans':>6s} {'global':>6s} "
          f"{'resid':>8s} "
          f"{'heads':>6s} "
          f"{'clamp':>5s} {'PICK':>10s} "
          f"{'NPR':>3s} {'branch':>8s} {'thresh':>8s} {'used':>8s} "
          f"{'d_may':>8s} {'d_refs':>8s} {'d_pin':>8s}")
    print(f"{'':>8s}  "
          f"{'GB':>7s} {'GB':>7s} "
          f"{'MB':>9s} {'MB':>8s} "
          f"{'MB':>9s} {'MB':>9s} "
          f"{'MB':>8s} {'MB':>8s} {'MB':>8s} "
          f"{'MB':>8s} {'MB':>8s} {'':>7s} {'':>5s} "
          f"{'MB':>6s} {'MB':>6s} {'MB':>6s} {'MB':>6s} "
          f"{'MB':>8s} "
          f"{'':>6s} "
          f"{'':>5s} {'':>10s} "
          f"{'':>3s} {'':>8s} {'MB':>8s} {'MB':>8s} "
          f"{'MB/s':>8s} {'MB/s':>8s} {'MB/s':>8s}")
    print("-" * 250)

def print_snapshot(s, prev, dt):
    ts = time.strftime("%H:%M:%S")

    if prev and dt > 0:
        d_may = mb(s['bytes_may_use'] - prev['bytes_may_use']) / dt
        d_refs = mb(s['delrefs_rsv_size'] - prev['delrefs_rsv_size']) / dt
        d_pin = mb(s['bytes_pinned'] - prev['bytes_pinned']) / dt
        d_may_s = f"{d_may:+8.1f}"
        d_refs_s = f"{d_refs:+8.1f}"
        d_pin_s = f"{d_pin:+8.1f}"
    else:
        d_may_s = f"{'---':>8s}"
        d_refs_s = f"{'---':>8s}"
        d_pin_s = f"{'---':>8s}"

    npr = 'YES' if s['npr_trigger'] else 'no'

    iblk = f"{mb(s['inode_blk_reserved']):8.1f}" if s['inode_blk_reserved'] >= 0 else f"{'n/a':>8s}"
    idel = f"{mb(s['inode_del_reserved']):8.1f}" if s['inode_del_reserved'] >= 0 else f"{'n/a':>8s}"
    ioe = f"{s['inode_oe_total']:7d}" if s['inode_oe_total'] >= 0 else f"{'n/a':>7s}"
    icnt = f"{s['inode_rsv_count']:5d}" if s['inode_rsv_count'] >= 0 else f"{'n/a':>5s}"

    print(f"{ts:>8s}  "
          f"{gb(s['dirty_bytes']):7.1f} {gb(s['writeback_bytes']):7.1f} "
          f"{mb(s['bytes_may_use']):9.1f} {mb(s['bytes_pinned']):8.1f} "
          f"{mb(s['delalloc_bytes']):9.1f} {mb(s['ordered_bytes']):9.1f} "
          f"{mb(s['delrefs_rsv_size']):8.1f} {mb(s['delrefs_rsv_reserved']):8.1f} {mb(s['delblock_rsv_reserved']):8.1f} "
          f"{iblk} {idel} {ioe} {icnt} "
          f"{mb(s['chunk_rsv_reserved']):6.1f} {mb(s['treelog_rsv_reserved']):6.1f} {mb(s['trans_rsv_reserved']):6.1f} {mb(s['global_rsv_reserved']):6.1f} "
          f"{mb(s['residual']):8.1f} "
          f"{s['num_heads']:6d} "
          f"{s['clamp']:5d} {s['would_pick']:>10s} "
          f"{npr:>3s} {s['npr_branch']:>8s} {s['npr_thresh']:8.1f} {s['npr_used']:8.1f} "
          f"{d_may_s} {d_refs_s} {d_pin_s}",
          flush=True)

# --- JSON output ---
def print_json(s, prev, dt):
    out = {
        'time': time.strftime("%H:%M:%S"),
        'dirty_gb': round(gb(s['dirty_bytes']), 2),
        'wb_gb': round(gb(s['writeback_bytes']), 2),
        'may_use_mb': round(mb(s['bytes_may_use']), 1),
        'pinned_mb': round(mb(s['bytes_pinned']), 1),
        'used_mb': round(mb(s['bytes_used']), 1),
        'reserved_mb': round(mb(s['bytes_reserved']), 1),
        'total_mb': round(mb(s['total_bytes']), 1),
        'delalloc_mb': round(mb(s['delalloc_bytes']), 1),
        'ordered_mb': round(mb(s['ordered_bytes']), 1),
        'rsv': {
            'delrefs_sz': round(mb(s['delrefs_rsv_size']), 1),
            'delrefs_rv': round(mb(s['delrefs_rsv_reserved']), 1),
            'delblock_sz': round(mb(s['delblock_rsv_size']), 1),
            'delblock_rv': round(mb(s['delblock_rsv_reserved']), 1),
            'trans_sz': round(mb(s['trans_rsv_size']), 1),
            'trans_rv': round(mb(s['trans_rsv_reserved']), 1),
            'global_sz': round(mb(s['global_rsv_size']), 1),
            'global_rv': round(mb(s['global_rsv_reserved']), 1),
            'chunk_sz': round(mb(s['chunk_rsv_size']), 1),
            'chunk_rv': round(mb(s['chunk_rsv_reserved']), 1),
            'treelog_sz': round(mb(s['treelog_rsv_size']), 1),
            'treelog_rv': round(mb(s['treelog_rsv_reserved']), 1),
        },
        'inode': {
            'blk_rv': round(mb(s['inode_blk_reserved']), 1) if s['inode_blk_reserved'] >= 0 else None,
            'del_rv': round(mb(s['inode_del_reserved']), 1) if s['inode_del_reserved'] >= 0 else None,
            'oe_total': s['inode_oe_total'] if s['inode_oe_total'] >= 0 else None,
            'count': s['inode_rsv_count'] if s['inode_rsv_count'] >= 0 else None,
        },
        'residual_mb': round(mb(s['residual']), 1),
        'heads': s['num_heads'],
        'clamp': s['clamp'],
        'pick': s['would_pick'],
        'npr': s['npr_trigger'],
        'branch': s['npr_branch'],
        'thresh_mb': round(s['npr_thresh'], 1),
        'npr_used_mb': round(s['npr_used'], 1),
    }
    if prev and dt > 0:
        out['d_may'] = round(mb(s['bytes_may_use'] - prev['bytes_may_use']) / dt, 1)
        out['d_refs'] = round(mb(s['delrefs_rsv_size'] - prev['delrefs_rsv_size']) / dt, 1)
        out['d_pin'] = round(mb(s['bytes_pinned'] - prev['bytes_pinned']) / dt, 1)
    print(json_mod.dumps(out), flush=True)

# --- Main loop ---
if not json_mode:
    print(f"Monitoring btrfs metadata pipeline (interval={interval}s)")
    print(f"Filesystem at /  transid={get_snapshot()['transid']}")
    print()
    print_header()

prev = None
count = 0
t_prev = time.monotonic()

try:
    while True:
        s = get_snapshot()
        t_now = time.monotonic()
        dt = t_now - t_prev

        if json_mode:
            print_json(s, prev, dt)
        else:
            print_snapshot(s, prev, dt)

        prev = s
        t_prev = t_now
        count += 1

        if max_count and count >= max_count:
            break

        # Re-print header every 20 lines (table mode only)
        if not json_mode and count % 20 == 0:
            print()
            print_header()

        time.sleep(interval)

except KeyboardInterrupt:
    pass

if not json_mode:
    print()
    print("=== Final state ===")
    s = get_snapshot()
    print(f"  dirty:              {gb(s['dirty_bytes']):10.1f} GB")
    print(f"  writeback:          {gb(s['writeback_bytes']):10.1f} GB")
    print(f"  bytes_may_use:      {mb(s['bytes_may_use']):10.1f} MB")
    print(f"  bytes_pinned:       {mb(s['bytes_pinned']):10.1f} MB")
    print(f"  delalloc_bytes:     {mb(s['delalloc_bytes']):10.1f} MB")
    print(f"  ordered_bytes:      {mb(s['ordered_bytes']):10.1f} MB")
    print()
    print(f"  --- Global RSVs (size / reserved) ---")
    print(f"  global_rsv:         {mb(s['global_rsv_size']):10.1f} / {mb(s['global_rsv_reserved']):10.1f} MB")
    print(f"  delayed_refs_rsv:   {mb(s['delrefs_rsv_size']):10.1f} / {mb(s['delrefs_rsv_reserved']):10.1f} MB  gap: {mb(s['delrefs_rsv_size'] - s['delrefs_rsv_reserved']):10.1f} MB")
    print(f"  delayed_block_rsv:  {mb(s['delblock_rsv_size']):10.1f} / {mb(s['delblock_rsv_reserved']):10.1f} MB")
    print(f"  trans_rsv:          {mb(s['trans_rsv_size']):10.1f} / {mb(s['trans_rsv_reserved']):10.1f} MB")
    print(f"  chunk_rsv:          {mb(s['chunk_rsv_size']):10.1f} / {mb(s['chunk_rsv_reserved']):10.1f} MB")
    print(f"  treelog_rsv:        {mb(s['treelog_rsv_size']):10.1f} / {mb(s['treelog_rsv_reserved']):10.1f} MB")
    print()
    if s['inode_blk_reserved'] >= 0:
        print(f"  --- Per-inode RSVs (summed, {s['inode_rsv_count']} inodes with non-zero) ---")
        print(f"  inode block_rsv:    {mb(s['inode_blk_reserved']):10.1f} MB")
        print(f"  inode delayed_rsv:  {mb(s['inode_del_reserved']):10.1f} MB")
    else:
        print(f"  --- Per-inode RSVs: unavailable ---")
    print()
    print(f"  residual:           {mb(s['residual']):10.1f} MB")
    print(f"  clamp:              {s['clamp']:10d}")
    print(f"  ref heads:          {s['num_heads']:10d}  (ready: {s['num_heads_ready']})")
    print(f"  action selection:   {s['would_pick']}")
    triggered, branch, thresh_mb, used_mb = emulate_need_preemptive_reclaim(s)
    print(f"  need_preempt_recl:  {'YES' if triggered else 'no'} ({branch}, thresh={thresh_mb:.1f} MB, used={used_mb:.1f} MB)")
