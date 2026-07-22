# btrfs extent_map LOGGING-split race — reproducer

Reproduces and validates the fix for the btrfs `btrfs_drop_extent_map_range()`
`EXTENT_FLAG_LOGGING` inversion introduced by **f86f7a75e2fb5f**
("btrfs: use the flags of an extent map to identify the compression type").

## The bug (dump-proven, arch-independent)

`btrfs_drop_extent_map_range()` clears `EXTENT_FLAG_LOGGING` on the **original**
extent map and copies it onto the **split** maps — the opposite of its own
comment and of the pre-f86f7a75 (e4cc1483) behaviour:

```c
flags = em->flags;                                    /* captures LOGGING */
em->flags &= ~(EXTENT_FLAG_PINNED | EXTENT_FLAG_LOGGING);  /* clears on original */
...
split->flags = flags;                                 /* stamps LOGGING on splits */
```

When a **partial-overlap** drop runs on an em while a fast fsync is logging it
(LOGGING set, `tree->lock` dropped around `log_one_extent`), the split is minted
with LOGGING set, placed on `modified_extents`, holding only the tree ref and no
logger. The EM shrinker later frees it while it's still listed -> corrupts
`modified_extents` -> RCU stall in `btrfs_log_inode` (crash), or the WARN in
`btrfs_free_extent_map` (`WARN_ON(!list_empty(&em->list))`).

Fleet WARN is present on x86 (T1_CPL/BGM/TRN, 6.13/6.18) and ARM (GRC, 6.16/7.1)
— NOT ARM/subpage-exclusive. The unwaited partial-overlap drop that triggers it
comes from ordered-extent completion (truncated-OE branch) and/or relocation.

## The fix (Fix B)

Restore e4cc1483: clear PINNED on the em, clear LOGGING on the **copy** used to
build the splits (so splits never carry LOGGING, and the original keeps it).
Toggle it at runtime with `btrfs.dbg_repro_fix_b`.

## Status

- Mechanism + Fix B **proven** on x86 via `proof` mode (forced partial drop that
  runs the *real, unmodified* `btrfs_drop_extent_map_range`; matches the vmcore
  victim exactly: `flags=0x28` LOGGING|CZSTD, `len < ram_bytes`). Result:
  `POISON_MINTED` fix_b=N -> 1, fix_b=Y -> 0.
- **Natural** trigger not yet reproduced on x86 (the truncated-OE path via
  `extent_io.c:1848` is subpage/64K-page favoured; x86's other paths are
  wait_ordered-barriered or `skip_pinned`-skipped). This harness targets an
  **ARM / 64K-page** box for the natural repro.

## Quick start (ARM box or ARM VM)

These scripts are also committed under `em-repro/` on the
`boris/em-logging-repro` kernel branch (internal origin), so one fetch gets the
kernel + scripts together.

1. Build + boot the debug kernel (branch on internal origin):

   ```sh
   git fetch origin boris/em-logging-repro
   git checkout boris/em-logging-repro
   make -j"$(nproc)"                 # native aarch64, or your usual cross-build
   # (CONFIG_BTRFS_FS=m recommended for the fast rmmod/modprobe loop)
   # install + boot this kernel on the ARM box / VM
   # the repro scripts are now in ./em-repro/  (cd em-repro)
   ```

   The debug changes are 6-file, ~120 lines, all in `fs/btrfs/` (module params +
   WARN probes + the `dbg_repro_fix_b` toggle). No upstream behaviour changes
   unless a `dbg_repro_*` knob is set.

2. On the ARM box, with a **scratch** block device (e.g. `/dev/nvme1n1`):

   ```sh
   modprobe btrfs
   ls /sys/module/btrfs/parameters/ | grep dbg_repro   # confirm knobs present

   # (0) sanity: prove the mechanism + fix on this kernel (any arch), fast:
   ./run-repro.sh proof    /dev/SCRATCH /mnt/scratch 60 300
   #   expect: POISON_MINTED fix_b=N >0 ; fix_b=Y ==0

   # (1) NATURAL truncated-OE (the real trigger; should fire on 64K-page):
   ./run-repro.sh truncate /dev/SCRATCH /mnt/scratch 180 300

   # (2) NATURAL everything (balance + dio + churn + fsync):
   ./run-repro.sh all      /dev/SCRATCH /mnt/scratch 180 300
   ```

   `run-repro.sh` mkfs's the device each run — **use a scratch device**.

## What to look for

- `POISON MINTED (fix_b=0): LOGGING split -> modified_extents ...` in `dmesg`
  = a poisoned em was created. Its WARN prints the **dropper stack** — the real
  caller that raced the log window (e.g. `btrfs_finish_one_ordered` on
  `btrfs-endio-write`, or `invalidate_extent_cache` under relocation).
- `DROP observed LOGGING em ... flags=0x28(...)` = a drop hit a LOGGING em.
  `list_empty=0` (modified) is the dangerous case.
- Success criterion for the natural repro: `POISON_MINTED > 0` with `fix_b=N`
  and `== 0` with `fix_b=Y`, where the dropper stack contains **no** `dbg_repro`
  forced call — i.e. a genuinely natural path.

## Module knobs (`/sys/module/btrfs/parameters/`, all default off)

| knob | effect |
|------|--------|
| `dbg_repro_ino` | target inode number for the delays/injectors (0 = off) |
| `dbg_repro_log_delay_ms` | msleep in the fast-fsync `log_one_extent` window (timing amplifier of a real race window) |
| `dbg_repro_fix_b` | Y = apply the candidate fix (clear LOGGING on the split copy) |
| `dbg_repro_skip_cow_werr` | skip the `COW_WRITE_ERROR` fast-fsync full-wait guard |
| `dbg_repro_force_ioerr` | force a write IO error on the target inode's OEs (error-path drop; full-remove leak variant) |
| `dbg_repro_force_partial_drop` | from `btrfs_finish_one_ordered`, drop `[file_offset+4K, end)` of the completed extent — models the truncated-OE/relocation PARTIAL drop (used by `proof` mode) |

`proof`/`ioerror` modes are FORCED (they set `force_*`), useful to validate the
kernel + Fix B on any arch. `truncate`/`dio`/`all` modes set **no** `force_*`
knobs — only `log_delay` — so a hit there is a genuine natural reproduction.

## Files

- `run-repro.sh`      — entry point (dispatch + fix_b A/B).
- `repro-workload.sh` — modes: `balance|ioerror|truncate(forced)|eof|mix`.
- `repro-truncate.sh` — NATURAL truncated-OE churn (sub-folio writes + non-aligned ftruncate).
- `repro-dio.sh`      — NATURAL DIO-invalidate-buffered (non-compressed).
- `repro-natural.sh`  — NATURAL combined (balance + dio + churn + fsync).
- `vmcore-rc7-*.drgn` — drgn scripts used to root-cause the original vmcore.
- `debug-report.txt`  — LKML-style writeup of the root cause + fix.
