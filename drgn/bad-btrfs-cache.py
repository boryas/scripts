#!/usr/bin/env drgn

import json
import sys

import drgn
from drgn import FaultError, NULL, Object, cast, container_of, execscript, offsetof, reinterpret, sizeof, stack_trace
from drgn.helpers.linux import *
from drgn.helpers.common import *
from collections import defaultdict

fs_info = cast("struct btrfs_fs_info *", path_lookup("/mnt/lol").mnt.mnt_sb.s_fs_info)
btree_inode = fs_info.btree_inode
mapping = btree_inode.i_mapping
PG_locked = prog["PG_locked"].value_()
PG_dirty = prog["PG_dirty"].value_()
PG_writeback = prog["PG_writeback"].value_()
PG_private = prog["PG_private"].value_()
PG_private_2 = prog["PG_private_2"].value_()
eb_dirty = prog["EXTENT_BUFFER_DIRTY"]
eb_writeback = prog["EXTENT_BUFFER_WRITEBACK"]
eb_tree_ref = prog["EXTENT_BUFFER_TREE_REF"]
PG_PRIVATE = 1 << PG_private | 1 << PG_private_2
PAGE_SIZE = int(prog["PAGE_SIZE"])

Total = 0
Fails = defaultdict(int)
Ok = 0
EbRefCounts = defaultdict(int)
Ebs = set()

def bump_fail(fail):
    Fails[fail] += PAGE_SIZE

def folio_has_private(folio):
    pflags = folio.flags.value_()

    return int(bool(pflags & PG_PRIVATE))

def release_eb(eb):
    ebflags = eb.bflags
    ebrc = int(eb.refs.counter)
    EbRefCounts[ebrc] += 1
    if ebrc == 0:
        bump_fail("eb-zero-refcount")
        return False
    if ebrc > 1:
        bump_fail("eb-refcount")
        return False
    if ebflags & (1 << eb_dirty):
        bump_fail("eb-dirty")
        return False
    if ebflags & (1 << eb_writeback):
        bump_fail("eb-writeback")
        return False
    return True

def release_folio(folio):
    pflags = folio.flags.value_()
    if not pflags & (1 << PG_private):
        bump_fail("no-private")
        return False
    eb = cast("struct extent_buffer *", folio.private)
    return release_eb(eb)

def mapping_evict_folio(mapping, folio):
    pflags = folio.flags.value_()
    if pflags & (1 << PG_locked):
        bump_fail("folio-locked")
        return False
    if pflags & (1 << PG_dirty):
        bump_fail("folio-dirty")
        return False
    if pflags & (1 << PG_writeback):
        bump_fail("folio-writeback")
        return False
    if folio._refcount.counter > 1 + folio_has_private(folio) + 1:
        bump_fail("folio-refcount")
        return False
    if not folio_has_private(folio):
        bump_fail("folio-has-private")
        return False
    return release_folio(folio)

flag_hist = defaultdict(int)
flag_hist_full = defaultdict(int)

def update_flag_hist(folio):
    flags = decode_page_flags(folio)
    flag_hist_full[flags] += 1
    for flag in flags.split("|"):
        flag_hist[flag] += 1

for index, entry in xa_for_each(mapping.i_pages.address_of_()):
    folio = cast("struct folio *", entry)
    try:
        Total += PAGE_SIZE
        if (Total >> 20) % 10 == 0:
            sys.stdout.write(f"\rScanned {Total >> 20}MiB")
            sys.stdout.flush()
        update_flag_hist(folio)
        
        if mapping_evict_folio(mapping, folio):
            Ok += PAGE_SIZE
    except drgn.FaultError:
        bump_fail("drgn-fault-error")
        continue

#print()
#json.dump(flag_hist_full, sys.stdout, indent=4)
print()
json.dump(flag_hist, sys.stdout, indent=4)
print()

Total_MiB = Total >> 20
Total_Pages = Total / PAGE_SIZE
Ok_MiB = Ok >> 20
Ok_Pages = Ok / PAGE_SIZE
Fails_MiB = {reason: bs >> 20 for reason, bs in Fails.items()}
Fails_Pages = {reason: bs / PAGE_SIZE for reason, bs in Fails.items()}
print(f"Total: {Total} Total MiB: {Total_MiB} Total Pages: {Total_Pages}")
print(f"Ok: {Ok} Ok MiB: {Ok_MiB} Ok Pages: {Ok_Pages}")
#print(f"Fails: {Fails}")
#print(f"Fails MiB: {Fails_MiB}")
print(f"Fails Pages: {Fails_Pages}")
print(f"Eb Ref Counts: {EbRefCounts}")
if Ok + sum([bs for reason, bs in Fails.items()]) != Total:
    print("Mismatched amounts!")
