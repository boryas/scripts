#!/usr/bin/env drgn

import sys

import drgn
from drgn import Object
from drgn.helpers.linux import (
    for_each_page,
    inode_path,
)

def mapping_to_name(mapping):
    if not m.host:
        return "no inode"
    p = inode_path(m.host)
    if not p:
        return mapping.a_ops
    return p

#memcg_ssid = prog["memory_cgrp_id"].value_()
PG_head = prog["PG_head"].value_()
PG_slab = prog["PG_slab"].value_()
PG_swapbacked = prog["PG_swapbacked"].value_()
PAGE_MAPPING_ANON = 0x1
PAGE_MAPPING_MOVABLE = 0x2
PAGE_MAPPING_FLAGS = PAGE_MAPPING_ANON | PAGE_MAPPING_MOVABLE
MEMCG_DATA_OBJCGS = prog["MEMCG_DATA_OBJCGS"].value_()
MEMCG_DATA_KMEM = prog["MEMCG_DATA_KMEM"].value_()
__NR_MEMCG_DATA_FLAGS = prog["__NR_MEMCG_DATA_FLAGS"].value_()
MEMCG_DATA_FLAGS_MASK = __NR_MEMCG_DATA_FLAGS - 1

nr_scanned = 0
mappings = {}
try:
    for page in for_each_page(prog):
        nr_scanned += 1
        if nr_scanned % 8192 == 0:
            sys.stdout.write(f"\rScanned {nr_scanned / 256:.0f}MB")
            sys.stdout.flush()
        try:
            memcg_data = page.memcg_data.value_()
            if memcg_data & (MEMCG_DATA_OBJCGS | MEMCG_DATA_KMEM):
                continue
            memcg = memcg_data & ~MEMCG_DATA_FLAGS_MASK
            if not memcg:
                continue
            memcg_obj = Object(prog, "struct mem_cgroup", address=memcg)
            if memcg_obj.address_of_() != prog['root_mem_cgroup']:
                continue

            pflags = page.flags.value_()

            if pflags & (1 << PG_slab):
                continue
            if page.compound_head.value_() & 1: # tail page
                continue

            mapping = page.mapping.value_()
            if pflags & (1 << PG_swapbacked) and page.private.value_() != 0:
                continue
            if mapping & PAGE_MAPPING_ANON:
                continue

            pgsz = 2 << 20 if pflags & (1 << PG_head) else 4 << 10

            if mapping in mappings:
                mappings[mapping] += pgsz
            else:
                mappings[mapping] = pgsz
        except drgn.FaultError:
            pass
except KeyboardInterrupt:
    pass
print("")

print("printing results")
for mapping in mappings:
    m = Object(prog, 'struct address_space', address=mapping)
    print("  %s: %d\n" % (mapping_to_name(m), mappings[mapping]))
