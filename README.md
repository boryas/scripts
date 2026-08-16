# scripts — btrfs kernel development tools

A collection of tools for btrfs kernel development. The tools do four kinds of
work:

- They make a known bug occur again (the reproducers).
- They measure the kernel while it runs (the tracing and profile tools).
- They read kernel memory or a crash dump (the drgn tools).
- They run tests and benchmarks on a fleet of machines, and they keep the
  results (the test infrastructure).

Upstream location: `https://github.com/boryas/scripts.git`.

---

## 1. About this document

### 1.1 Table convention

The tables have two columns: the file and its function. In the function column,
the subject is always the file itself. Each entry starts with the verb. Read
`Counts the calls.` as `The script counts the calls.`

### 1.2 Technical names

This document uses these technical names. They are not standard English words,
but they are necessary:

`bpftrace`, `btrfs`, `btrd`, `block group`, `cgroup`, `chunk`, `COW`, `dev
extent`, `drgn`, `extent`, `extent map`, `fio`, `fsperf`, `fstests`, `kernel`,
`qemu`, `qgroup`, `rcli`, `reflink`, `snapshot`, `squota`, `subvolume`,
`sysfs`, `vmcore`.

### 1.3 Technical verbs

This document uses these technical verbs:

`to allocate`, `to balance`, `to commit`, `to compress`, `to dispatch`, `to
enable`, `to flush`, `to mkfs`, `to mount`, `to publish`, `to reclaim`, `to
relocate`, `to snapshot`, `to sync`, `to trace`, `to unmount`.

---

## 2. Top-level structure

| Directory | Language | Function |
| --- | --- | --- |
| `bt/` | bpftrace | Traces the kernel and measures latency. 52 files. |
| `c/` | C | Makes small user-space programs that cause a specific kernel path. 19 files. |
| `drgn/` | Python (drgn) | Reads kernel memory or a vmcore. 14 files. |
| `fio/` | fio and shell | Runs disk workloads. 8 files. |
| `frag/` | btrd, shell, Python | Makes fragmentation and measures it. 8 files. |
| `py/` | Python | Holds general Python tools. 1 file. |
| `rust/` | Rust | Draws a picture of the free space of a filesystem. 5 files. |
| `sh/` | shell, Python | Holds the reproducers, the experiments and the test infrastructure. 304 files. |


---

## 3. The shared shell framework

### 3.1 The libraries

The shell scripts in `sh/` include a small set of libraries. A script sets
`SH_ROOT` to the `sh/` directory, then it includes the library that it needs.

| File | Function |
| --- | --- |
| `sh/boilerplate.sh` | Gives the colours and the message functions (`_log`, `_err`, `_fail`, `_ok`, `_sad`, `_happy`). Also gives `_kmsg` (writes to `/dev/kmsg`), `_sleep`, `_elapsed` and `_cleanup`. |
| `sh/fs.sh` | Gives the mount helpers: `_cycle_mnt`, `_umount`, `_umount_loop`. Also gives the `<dev> <mnt>` argument check `_basic_dev_mnt_usage`. |
| `sh/btrfs.sh` | Gives the btrfs helpers: `_fresh_btrfs_mnt`, `_btrfs_mnt`, `_btrfs_uuid`, `_btrfs_sysfs`, `_btrfs_sysfs_space_info`. |
| `sh/squota.sh` | Gives the simple-quota helpers: `_fresh_squota_mnt`, `_wait_for_deletion`, `_check_qgroup_leak`. |
| `sh/qgroup/qgroup.sh` | Gives the qgroup report helpers: `_qgroup_show`, `_squota_json`, `_squota_subvol`, `_inspect_owned_metadata`. |
| `sh/fs.h` | Is an empty C header. It has no content. |

### 3.2 The `rcli` command layout

Some directories in `sh/` are command trees for the `rcli` dispatcher. A
command directory always has this layout:

| File | Function |
| --- | --- |
| `run` | Runs the command. A parent `run` only prints the usage text. |
| `usage` | Gives the one-screen usage text. |
| `help` | Gives the longer help text. This file is optional. |
| `Makefile` | Installs the command. The `install` target makes symbolic links in `~/.rcli/clis/<name>/`. |

A subcommand is a subdirectory with the same layout. To install a command
tree, go to its directory and run `make install`.

These directories are command trees: `sh/vm/`, `sh/vm-baseline/`,
`sh/fstests-ctx/`, `sh/fstests-utils/`, `sh/fsperf-utils/`, `sh/btrfs-scale/`.

### 3.3 The usual call pattern

Most reproducers take a scratch device and a mount point:

```sh
./run.sh <dev> <mnt>
```

**Warning:** these scripts almost always do a `mkfs` on the device. Use a
scratch device only.

---

## 4. `bt/` — the bpftrace scripts

Run a `.bt` file with `sudo bpftrace <file>`.

### 4.1 The allocator

| File | Function |
| --- | --- |
| `bt/alloc/alloc.bt` | Prints each insert and each delete of a data extent, a metadata extent and a block group. |
| `bt/alloc/ffe.bt` | Makes a histogram of the request size at `find_free_extent`. |
| `bt/alloc/time-ffe.bt` | Makes a histogram of the `find_free_extent` latency. |
| `bt/alloc/unused.bt` | Traces the add, the remove, the unused and the skip events of a block group. |
| `bt/ffe.bt` | Counts the loops, the block groups tried and the chunk allocations for each data `find_free_extent` call. |
| `bt/ffe2.bt` | Is a cut-down version of `ffe.bt`. |
| `bt/ffe/loops.bt` | Prints a time line of the `find_free_extent` loop count and of the block groups per loop. |
| `bt/chunk-alloc.bt` | Prints the time, the pid, the command and the stack of each `btrfs_alloc_chunk`. |
| `bt/hot-groups.bt` | Counts the hot and the hinted allocation hits, and the hot allocation failures. |
| `bt/enospc/free.bt` | Reports the free space that does not merge. Makes a histogram of the hole size. |
| `bt/enospc/who-alloc.bt` | Shows which command causes a chunk allocation and which command calls `fallocate`. |
| `bt/reclaim/reclaim.bt` | Prints the life time of a block group and its allocation count at reclaim. |
| `bt/reclaim/fails.bt` | Prints the stack when block group relocation fails. |

### 4.2 The locks and the latency

| File | Function |
| --- | --- |
| `bt/cow_lock_cost.bt` | Profiles the COW lock contention. Emits three event types: the victim (blocked), the villain (the COW itself) and the villain cost (the total victim wait). |
| `bt/extent_lock_cost.bt` | Profiles the extent range lock. Emits the acquire time, the hold time and the partial-range unlock. |
| `bt/extent_bits.bt` | Puts the extent lock stack and the extent unlock stack together for `find_lock_delalloc_range`. |
| `bt/slow-fsync/slow-stacks.bt` | Reports a slow `btrfs_sync_file` and the locks inside it. |
| `bt/slow-fsync/slow-locks.bt` | Reports a slow mutex acquire and a slow mutex hold inside fsync and inside commit. |
| `bt/slow-fsync/why-long-lock.bt` | Reports a slow transaction commit and the locks inside it. |
| `bt/bt-kstack.sh` | Counts the kernel stacks at a function that you name. Is a bpftrace one-liner. |
| `bt/bt-timing-hist.sh` | Makes latency histograms (ns, us and ms) for a function that you name. |

### 4.3 The pressure and the flush pipeline

| File | Function |
| --- | --- |
| `bt/btrfs-pressure/btrfs-pressure.bt` | Measures the latency of five blocking btrfs functions. Prints the command, the cgroup and the stack. |
| `bt/btrfs-pressure/pressure-msl.bt` | Does the same, but emits the StrobeLight tuple format. |
| `bt/btrfs-pressure/gen.sh` | Makes `btrfs-pressure.bt` from a list of function names. |
| `bt/btrfs-pressure/gen-msl.sh` | Makes `pressure-msl.bt` from a list of function names. |
| `bt/btrfs-pressure/parse_pressure.sh` | Changes the cgroup inode numbers in the output into cgroup paths. Changes ns into ms. |
| `bt/flush_effectiveness.bt` | Measures how much space each `flush_space` call frees. Reports the `bytes_may_use` delta, the pinned delta, the delayed-ref-head delta, the time and the clamp. |
| `bt/flush_pipeline.bt` | Traces the full metadata reclaim pipeline: the flush actions, the inode reserve exhaustion and the ordered extent counts. |
| `bt/delayed_refs_callers.bt` | Finds the callers of `btrfs_update_delayed_refs_rsv`. Also finds the inode delayed-reserve shortfalls. |

### 4.4 The I/O paths and the page cache

| File | Function |
| --- | --- |
| `bt/bio.bt` | Reports a slow `btrfs_readpage` and a slow `btrfs_writepages`, and the bios below them. The limit is 100 ms. |
| `bt/csum/bio_csum.bt` | Reports the checksum lookup errors inside `btrfs_lookup_bio_sums`. |
| `bt/drop_caches.bt` | Prints the stacks inside `drop_pagecache_sb`. |
| `bt/release_eb.bt` | Traces the invalidation of the btree inode pages during `drop_caches`. |
| `bt/release-eb-folio.bt` | Checks the release of the extent buffer folios against the allocation. |
| `bt/compr-leak.bt` | Tracks the compressed folios that leak. |
| `bt/page-fault/page-fault.bt` | Counts the page cache adds per command and per inode during a page fault. |
| `bt/kvm-dirty/kvm-dirty.bt` | Counts the pages that KVM makes dirty, per inode and per stack. |
| `bt/recow.bt` | Prints the COW block events, the extent buffer writes, the commits and the syncs. |

### 4.5 The references, the quota and the metadata

| File | Function |
| --- | --- |
| `bt/dup-meta-ref/dup-meta-ref.bt` | Finds a duplicate delayed tree ref and a missing delayed tree ref. |
| `bt/ref-verify/ref-verify.bt` | Counts the tree ref referrers and the referents from the delayed tree refs. |
| `bt/btrfs_inode.bt` | Counts the `btrfs_new_inode` calls per command. |
| `bt/readdir.bt` | Counts the readdir calls on inode 256. |
| `bt/hardlink.bt` | Puts a time stamp on each function in a `linkat` system call. |
| `bt/subvol-mkdir.bt` | Shows the command that makes a directory with the name of a subvolume that was deleted. |
| `bt/fallocate/fallocate.bt` | Prints the fallocate calls. Makes a histogram of the size. |

### 4.6 The other subsystems

| File | Function |
| --- | --- |
| `bt/blkdiscard.bt` | Finds the callers of the discard ioctl on a block device that has holders. |
| `bt/epipe.bt` | Reports the `EPIPE` returns from `sk_stream_wait_connect` and from `splice_to_pipe`. |
| `bt/kernfs/put_race.bt` | Prints the `kernfs_put` and the `kernfs_find_ns` events for a refcount race. |
| `bt/tramp.bt` | Prints the BPF trampoline link, update and text-poke results. |
| `bt/verity-exec.bt` | Counts the executable file opens with fs-verity and without fs-verity. |
| `bt/xfs_inode.bt` | Counts the XFS inode pin and unpin events during reclaim. |
| `bt/xhci.bt` | Prints the USB hub events and the xHCI events. |

---

## 5. `c/` — the C programs

To build all the programs, run `make` in `c/`. Git ignores the binaries.

| File | Function |
| --- | --- |
| `c/Makefile` | Builds each `.c` file into a program with the same name. |
| `c/atomic-update.c` | Writes a file with the write-to-temporary-file and rename pattern. |
| `c/chunk-write.c` | Allocates 1 GiB, then writes it in 100 MiB parts with `pwritev`. |
| `c/gen-frag.c` | Makes many small files, then deletes half of them, to make fragmentation. |
| `c/holepunch-write.c` | Punches holes in a file and writes to the same file. |
| `c/holepunch-write.h` | Is an empty header. It has no content. |
| `c/limits.c` | Prints the size and the maximum value of each C integer type. |
| `c/mount-by-fd.c` | Mounts btrfs through `/proc/self/fd` paths, in a new mount namespace. |
| `c/multi-open.c` | Opens many files, maps them into memory, then reads the pages. |
| `c/o_tmpfile.c` | Makes an `O_TMPFILE` file, syncs it, then links it into the directory. |
| `c/open-file.c` | Opens a file and sleeps for one hour. Keeps the inode in use. |
| `c/pgfault.c` | Makes page faults with a malloc and read/write loop. |
| `c/pgfault.bt` | Counts the page fault stacks of the `pgfault` program. |
| `c/pwrite.c` | Truncates a file, sleeps, then writes past the old end of the file. |
| `c/sign-ext.c` | Prints the sign extension results for 2 GiB and for -1. |
| `c/squota-demo.c` | Makes qgroups, sets a limit, and snapshots with `--inherit`. Uses the ioctls directly. |
| `c/run-squota.sh` | Runs `squota-demo` against a fresh squota filesystem, then checks that the limit holds. |
| `c/unshare-mount-dev.c` | Opens a loop device, then unshares the mount namespace. |
| `c/chunk-write-shas` | Holds the recorded checksums from `chunk-write` runs. Is data, not code. |

---

## 6. `drgn/` — the kernel memory tools

Run these tools on a live kernel with `sudo drgn <file> <args>`. Run them on a
crash dump with `drgn -s <vmlinux> -c <vmcore> <file>`.

### 6.1 The chunk allocation group

These seven tools all look at one bug: an `EEXIST` error when the kernel
inserts a dev extent. See also `sh/dev-extent-race/`.

| File | Function |
| --- | --- |
| `drgn/dump_chunk_allocated.py` | Prints the `CHUNK_ALLOCATED` bits of each device. These bits mark the allocations that are not yet committed. |
| `drgn/dump_chunk_maps.py` | Prints the chunk maps and the dev extents. Finds the physical address overlaps. Has a quiet mode. |
| `drgn/dump_commit_root_dev_extents.py` | Prints the dev extents in the commit root. This is the view that `find_free_dev_extent` gets. |
| `drgn/dump_dev_extents_btree.py` | Prints the dev extents from the commit root and from the current root. Shows the difference. |
| `drgn/show_allocator_view.py` | Shows the holes that `find_free_dev_extent` sees, against the `CHUNK_ALLOCATED` bits. |
| `drgn/verify_chunk_allocated.py` | Compares the `CHUNK_ALLOCATED` bits, the chunk maps and the commit root dev extents. |
| `drgn/detect_allocation_gap_bug.py` | Finds a large dev extent hole that holds two or more separate `CHUNK_ALLOCATED` ranges. This is the bug condition. Exits 1 if it finds one. |

### 6.2 The other tools

| File | Function |
| --- | --- |
| `drgn/dump-stacks.drgn` | Writes the stack of every task to a file. Takes an optional text filter. |
| `drgn/fd-dpath.drgn` | Walks the dentry path of a file descriptor, step by step. |
| `drgn/folio-invalidate-sim.py` | Examines the btree inode folios and the extent buffer flags. |
| `drgn/free-space-cache.drgn` | Prints the free space extents of a data block group. |
| `drgn/inspect-qgroups.py` | Prints the qgroup hierarchy that is in memory. Use it for a squota leak. |
| `drgn/qg-rsv.drgn` | Prints the `io_tree` of a file and the qgroup identifiers. |
| `drgn/shared-extent-pages.drgn` | Maps the page cache pages to their extents and to the inodes that share them. |

---

## 7. `fio/` — the disk workloads

| File | Function |
| --- | --- |
| `fio/many-files/many-files.fio` | Writes 400000 files of 4 KiB. |
| `fio/many-files/run.sh` | Runs a loop: fio, snapshot, balance, delete, then `btrfs check`. Stops if the check fails. |
| `fio/reclaim/frag.sh` | Drives the reclaim experiment. Runs each workload against each reclaim configuration. Collects the sysfs statistics. |
| `fio/reclaim/graph.py` | Draws the collected statistics with matplotlib. |
| `fio/reclaim/thresh_sim.py` | Simulates the dynamic reclaim threshold formula against disks of different sizes. |
| `fio/try-parallel/try-parallel.fio` | Runs 32 jobs. Each job writes small files. There are 100000 files. |
| `fio/try-parallel/try-parallel.sh` | Makes a btrfs filesystem across N devices, then runs `try-parallel.fio`. |

---

## 8. `frag/` — the fragmentation tools

| File | Function |
| --- | --- |
| `frag/setup.sh` | Makes a fresh btrfs filesystem and the work directory. |
| `frag/frag.sh` | Makes fragmentation. Runs 32 buffered write loops and 4 fallocate loops together. |
| `frag/man-frag.sh` | Makes fragmentation with a small, fixed set of manual steps. Prints the usage after each step. |
| `frag/self-contained.sh` | Runs `setup.sh`, then `frag.sh`. |
| `frag/bg-dump.btrd` | Prints each block group and each extent inside it. Is a btrd script. |
| `frag/bg-frag.btrd` | Prints the free space and the extent owners for each data block group. Is a btrd script. |
| `frag/process-bg-frag.py` | Reads the `bg-frag` output. Groups the extents into contiguous used areas and free areas. Prints the statistics. |
| `frag/sort-stream.sh` | Sorts an allocation event stream by time. |

---

## 9. `py/` — the Python tools

| File | Function |
| --- | --- |
| `py/commit-to-series` | Maps a git commit to its patch series on `lore.kernel.org`. Finds the original mail with `lei`, gets the full series with `b4`, then maps each patch back to a commit. Takes one or more commits, or a range. |

---

## 10. `rust/` — the picture tool

| File | Function |
| --- | --- |
| `rust/btrfs-frag-view/src/main.rs` | Draws the fragmentation of a filesystem as an image. Uses a Hilbert curve to map the address space to pixels. Also prints the statistics. |
| `rust/btrfs-frag-view/Cargo.toml` | Lists the dependencies: `image`, `fast_hilbert`, `clap` and `statrs`. |
| `rust/btrfs-frag-view/Cargo.lock` | Locks the dependency versions. |
| `rust/btrfs-frag-view/cleanup.sh` | Deletes the output images and the text files. |

---

## 11. `sh/` — the shell scripts

This is the largest directory. It has four kinds of content:

1. The shared libraries. See section 3.
2. The test and benchmark infrastructure. See section 11.2.
3. The bug reproducers. See section 11.3.
4. The experiment and workload scripts. See section 11.4.

### 11.1 The single-file scripts

| File | Function |
| --- | --- |
| `sh/clm-xarray.sh` | Makes an XFS filesystem, starts eight readers, then compacts the memory in a loop. |
| `sh/reload_btrfs.sh` | Unmounts, removes the btrfs module, loads it again, then mounts. |
| `sh/systemd-repart-repro.sh` | Runs `systemd-repart` against a btrfs image, then runs it again in a new mount namespace. |
| `sh/unalloc.sh` | Balances the filesystem in steps until the unallocated space reaches a target. Increases `dusage` after each try. |
| `sh/chunk-alloc-wq.sh` | Is empty. It is a placeholder. |

---

### 11.2 The test and benchmark infrastructure

These are `rcli` command trees. They are the most developed part of the
repository.

#### 11.2.1 `sh/vm/` — the qemu VM manager

This is a small replacement for libvirt. It keeps the VM state in the file
system, under `$VM_DIR`.

| File | Function |
| --- | --- |
| `sh/vm/run` | Prints the usage. Is the parent command. |
| `sh/vm/usage`, `sh/vm/help` | Give the usage text and the help text. |
| `sh/vm/common` | Reads `~/.config/rcli/env` and includes `boilerplate.sh`. Each subcommand includes this file. |
| `sh/vm/list/run` | Lists each VM with its state: `UP`, `DOWN` or `UNREACHABLE`. |
| `sh/vm/up/run` | Starts a VM. Runs qemu in the background, or in the foreground on request. |
| `sh/vm/down/run` | Stops a VM. Sends a graceful shutdown over ssh. Kills the VM after 15 seconds. |
| `sh/vm/kill/run` | Kills the qemu process itself. Uses `SIGKILL` after 30 seconds. |
| `sh/vm/cycle/run` | Stops a VM, then starts it again. Accepts `all`. |
| `sh/vm/ready/run` | Blocks until the VM answers an ssh command. |
| `sh/vm/ssh/run` | Waits until the VM is ready, then opens an ssh session. |
| `sh/vm/cons/run` | Attaches to the serial console of a VM. Uses `socat` inside a `screen` session, so you can detach and come back. |
| `sh/vm/Makefile` and the subdirectory Makefiles | Install the command tree into `~/.rcli/clis/vm/`. |

#### 11.2.2 `sh/vm-baseline/` — the A/B performance run

| File | Function |
| --- | --- |
| `sh/vm-baseline/run` | Builds a baseline commit and an experiment commit in turn. Boots each one in the same VM. Runs `fsperf` N times on each. Compares the results. |
| `sh/vm-baseline/usage` | Gives the argument list: `<linux_dir> <baseline-commit> <experiment-commit> <vm>`. |

#### 11.2.3 `sh/fstests-ctx/` — the fstests context switch

| File | Function |
| --- | --- |
| `sh/fstests-ctx/run` | Changes the fstests context. Updates the fstests tree, the btrfs-progs tree and `local.config`. Runs `mkfs` on the test device with the options for the context. |
| `sh/fstests-ctx/help` | States why the command exists. The fstests need system state: the user-space tools, the mkfs options and `local.config`. |
| `sh/fstests-ctx/usage` | Lists the contexts: `squota`, `quota` and `default`. |

#### 11.2.4 `sh/fstests-utils/` — the parallel fstests pipeline

This command tree runs the fstests across a fleet of workers. It keeps the
results for a long time. It finds a regression against the `for-next`
baseline.

| File | Function |
| --- | --- |
| `sh/fstests-utils/INFRA.md` | Describes the infrastructure. Read this file first. It has the pipeline diagram, the DigitalOcean details, the host details and the notes that took time to find. |
| `sh/fstests-utils/test/run` | Is the main entry point. Builds the kernel, provisions the workers, dispatches `-g auto` in parallel, retries the failures with a longer limit, makes the digest and folds it into the history. |
| `sh/fstests-utils/adhoc/run` | Runs a named list of tests on the workers that are already up. Does no build, no provision and no digest. |
| `sh/fstests-utils/results/run` | Shows the difference in verdicts against the latest `for-next` run. Also prints the raw file, the JSON digest, or the history of one test. |
| `sh/fstests-utils/digest/run` | Reads a raw result file and makes `<sha>.json`. Reads two input formats: the JSONL format and the older line format. |
| `sh/fstests-utils/state/run` | Folds each `<sha>.json` into a per-test verdict history at `history.json`. Is idempotent. |
| `sh/fstests-utils/backfill/run` | Makes the digests that are missing. Use it once, to bootstrap. |
| `sh/fstests-utils/kp/run` | Classifies each test into a known-problem tier from `history.json`: `persistent_fail`, `flaky_unreliable`, `flaky_occasional` and `reliable_pass`. Answers the question "is this failure expected?". |
| `sh/fstests-utils/interpret/run` | Reads the JSONL from an adhoc run on standard input. Compares each result against the known-problem baseline. Marks the rows `POTENTIAL REGRESSION` or `POTENTIAL FIX`. |
| `sh/fstests-utils/artifacts/run` | Reads the JSONL of one phase. Copies the failure artifacts (`.out.bad`, `.full`, `.dmesg`) off each worker with rsync. |
| `sh/fstests-utils/release-on-drain/run` | Reads the JSONL on standard input and writes it through. When a worker drains, it first copies the artifacts, then it deletes the worker. The order is important: after the delete, the files are gone. |
| `sh/fstests-utils/html/run` | Makes the static HTML dashboards from the JSON digests: the branch picker, the per-branch page and the per-test time line. |
| `sh/fstests-utils/publish/run` | Copies the scripts and the results to the web host `s1`, then starts the HTML build there. |
| `sh/fstests-utils/cron/for-next` | Is the daily job. Fetches `btrfs/for-next`, runs the tests in the `linux-fnext` worktree, and folds the digest into the history. A systemd user timer starts it. |
| `sh/fstests-utils/selftest/run` | Checks the digest parser and the verdict logic. Takes less than one second. Run it after each change to the parser. |
| `sh/fstests-utils/tests.yaml` | Holds the per-test operator data: `slow`, `schedule: persistent_hang`, `schedule: para_skip` and the investigation notes. Replaces four older files. |
| `sh/fstests-utils/tests/run` | Queries `tests.yaml`. Lists the slow tests, the tests with a schedule, the metadata of one test, and the per-task time budgets. |
| `sh/fstests-utils/workers/local-vm/{up,down,list,ready}` | Give the worker backend for the local VMs `v0` to `v4`. Call through to `rcli vm`. |
| `sh/fstests-utils/workers/local-vc/{up,down,list,ready}` | Give the worker backend for the local VMs `vc0` to `vc4`. These VMs use a cloud image. They share the disks with the `v*` family, so do not run both families at the same time. |
| `sh/fstests-utils/workers/cloud/*` | Are symbolic links into the separate `cloud-fstests` repository. They give the DigitalOcean backend. |
| `sh/fstests-utils/workers/aws-arm64/*` | Are symbolic links into the separate `cloud-fstests` repository. They give the AWS arm64 backend. |

The `test` command takes these environment variables:

| Variable | Function |
| --- | --- |
| `WORKERS` | Selects the worker backend. The default is `local-vm`. |
| `FAST_ONLY` | Drops the slow tests and the medium tests. |
| `PUBLISH` | Folds the run into `history.json` and pushes it to `s1`. The default is off. |

#### 11.2.5 `sh/fsperf-utils/` — the fio benchmark pipeline

This command tree runs a matrix of fio workloads on cloud machines. It applies
statistics to the results to find a true performance change.

| File | Function |
| --- | --- |
| `sh/fsperf-utils/bench/run` | Is the main entry point. Provisions N machines, dispatches the workload matrix, collects the raw fio output and makes one summary for each sample. |
| `sh/fsperf-utils/cells/run` | Makes the task list. Takes the Cartesian product of the jobs and the profiles. Drops each pair that the profile marks as not compatible. |
| `sh/fsperf-utils/fio-runner` | Runs on the worker. Does a `mkfs` and a mount with the mount options of the profile, runs one fio job, then unmounts. Prints only the fio JSON on standard output. |
| `sh/fsperf-utils/digest/run` | Makes one summary JSON from the raw fio output of one machine. |
| `sh/fsperf-utils/history/run` | Walks the summaries and prints a table. Has three modes: per run, per job, and one metric only. |
| `sh/fsperf-utils/compare/run` | Compares two sets of samples. Flags a median shift and a variance shift. Reports the regressions, the improvements and the variance changes. |
| `sh/fsperf-utils/evaluate/run` | Applies the Shewhart rules to a candidate run against the accumulated baseline. Uses the median and the MAD, not the mean and the standard deviation, because a cloud machine sometimes gives one very fast sample. |
| `sh/fsperf-utils/trend/run` | Looks for one step change in the last N samples of each workload. Can inject an artificial change, to test the detector. |
| `sh/fsperf-utils/survey/run` | Gives the standing review. Prints the workload tier table (which workloads you can trust for a single night) and the recent moves that hold for several nights. |
| `sh/fsperf-utils/html/run` | Renders the results to static HTML: the branch picker, the per-branch dashboard, the per-job charts and the per-run detail. Uses uPlot for the charts. |
| `sh/fsperf-utils/publish/run` | Copies the scripts and the results to `s1`, then starts the HTML build there. |
| `sh/fsperf-utils/cron/for-next` | Is the periodic job. Runs one session of the matrix, six times each day. Each session adds one sample per workload to the baseline. |
| `sh/fsperf-utils/run.sh` | Is the older, simpler script. Runs `fsperf` on one VM for a baseline commit and for a test commit. |
| `sh/fsperf-utils/jobs/*.fio` | Hold the ten fio jobs. Five are buffered and five are direct I/O. Each set has append, random read, random write, sequential read and sequential write. |
| `sh/fsperf-utils/profiles/default.profile` | Gives a plain btrfs mount, with no extra options. |
| `sh/fsperf-utils/profiles/nodatacow.profile` | Gives a `nodatacow` mount. This turns off COW and checksums. |
| `sh/fsperf-utils/profiles/zstd.profile` | Gives a `compress-force=zstd:3` mount. Excludes the direct I/O write jobs, because direct I/O writes skip compression. |

**Important note from `survey/run`:** the nightly runs use one sample per
workload (K=1). More samples in one run do not help. All the samples in one
run share the same machine, so they measure one machine draw. Only separate
nights draw a new machine.

#### 11.2.6 `sh/btrfs-scale/` — the scale generators

| File | Function |
| --- | --- |
| `sh/btrfs-scale/files/run` | Makes N files of 128 KiB in a directory. |
| `sh/btrfs-scale/extents/run` | Appends N extents of 8 KiB to one file. Syncs after each append. |
| `sh/btrfs-scale/snapshots/run` | Makes N snapshots of a subvolume. |

---

### 11.3 The bug reproducers

Each directory holds the scripts for one bug. Five directories have their own
`README.md` or report. Read that file first.

Many directories follow the same three-script pattern:

| Script | Function |
| --- | --- |
| `standalone-minimal.sh` | Is self-contained. It has no dependencies. Send this file to an external developer. |
| `<bug>-minimal.sh` | Does the same, but it uses the shared libraries of this repository. |
| `parallel-test.sh` | Runs the same steps with several workers, for a set time. Use it to stress a fix. |

#### 11.3.1 `sh/em-logging-reloc-race/` — the extent map LOGGING split race

The largest reproducer. It has a full `README.md` and a `debug-report.txt`.

The bug: `btrfs_drop_extent_map_range()` clears `EXTENT_FLAG_LOGGING` on the
original extent map and copies it onto the split maps. This is the opposite of
the correct behaviour. The shrinker then frees a split map that is still on
the `modified_extents` list. This corrupts the list and causes an RCU stall in
`btrfs_log_inode`.

| File | Function |
| --- | --- |
| `README.md` | Describes the bug, the fix, the state of the work and the quick start. |
| `debug-report.txt` | Is the full report, 312 lines. |
| `run-repro.sh` | Is the one-command entry point. Takes a mode: `proof`, `truncate`, `dio`, `natural` or `all`. **Runs a `mkfs` on the device each time.** |
| `repro-workload.sh` | Runs the guest-side workload. Drives the drop from one of four sources: `balance`, `ioerror`, `eof` or `mix`. |
| `repro-truncate.sh` | Makes real truncated ordered extents with a write and an `ftruncate` into the write. This is the natural trigger. |
| `repro-dio.sh` | Makes a truncated ordered extent with a direct I/O write over a buffered dirty range. |
| `repro-natural.sh` | Runs every natural source together against one file that is under continuous fsync. |
| `walk_modified_extents.drgn` | Walks the `modified_extents` list of an inode. Detects a cycle. Dumps the state of each extent map. |
| `vmcore-rc7-victim.drgn` | Analyses the extent map that the diagnostic `BUG()` caught in the rc7 vmcore. |
| `vmcore-rc7-context.drgn` | Dumps the whole list, the rbtree state and each task that logs the inode or relocates. |
| `vmcore-rc7-ordered.drgn` | Dumps the fsync and ordered extent state of the inode. Scans the tasks for a writeback actor. |

#### 11.3.2 `sh/dev-extent-race/` — the dev extent `EEXIST` race

The bug: `btrfs_create_pending_block_groups` returns `EEXIST`. A balance frees
a dev extent while `force_chunk_alloc` inserts one at the same physical
offset. See the seven tools in `drgn/` (section 6.1).

| File | Function |
| --- | --- |
| `standalone-minimal.sh` | Is the self-contained reproducer. |
| `parallel-test.sh` | Runs the balance worker and the force-allocate worker together, for a set time. |
| `concurrent-race.sh` | Runs the balance and the cleaner in the background while it forces the allocations. |
| `same-transaction-gap.sh` | Makes the chunks and removes them in the same transaction. The commit root then shows one large hole, but the bitmap shows gaps. |
| `staggered-holes.sh` | Makes a staggered pattern of holes. Writes 32 files, then deletes all but every eighth file. |
| `window-race.sh` | Uses a 5-second sleep that a debug patch adds before the commit root switch. Allocates inside that window. |
| `observe-gap.sh` | Uses the same 5-second window, but only reads the state. Does not allocate. |
| `observe-gap2.sh` | Does the same with 1 GiB files, so that each file gets its own chunk. |
| `hole-size.sh` | Is a short stub. It only checks the arguments. |

#### 11.3.3 `sh/noisy-neighbor/` — the CPU starvation lock stall

The bug: global direct reclaim takes all the CPU time. A task that holds a
btrfs lock cannot get back on the CPU. The lock hold time grows. This
directory holds 51 files, because it holds a large measurement campaign.

| File | Function |
| --- | --- |
| `standalone-minimal.sh` | Is the self-contained reproducer. A memory hog fills the RAM. All the tasks share one CPU. |
| `standalone.sh` | Is the longer version, with cgroups for the good neighbour and the bad neighbour. |
| `run.sh` | Is the repository version of `standalone.sh`. Uses the shared libraries. |
| `run-repro.sh` | Runs the reproducer with the lock monitor beside it. |
| `run-ab.sh` | Runs the reproducer with the reclaim workers and without them. Compares the two. |
| `run-hack-workers.sh` | Runs the reproducer with the user-space reclaim workers. |
| `run-perf.sh`, `run-perf-diag.sh` | Sample the CPU with `perf` in the middle of the workload. |
| `run-alloc-trace.sh` | Runs the allocation trace at one fixed configuration. |
| `reclaim-worker.sh` | Starts the user-space reclaim workers. They act like more parallel kswapd threads. |
| `runnable_lock_monitor.bt` | Is the main measurement tool, 432 lines. Finds a lock holder that is on the run queue but not on a CPU. Reports the time, the waiters and the hold time. |
| `hold_and_slice.bt` | Measures the time slice use and the lock hold time together. Splits the results by reclaim. |
| `lock_alloc_trace.bt` | Traces each page allocation that happens while the task holds a sleeping lock. |
| `monitor.bt` | Compares the wall-clock time and the CPU time of `btrfs_search_slot`. A large difference proves the starvation. |
| `big-read.c`, `rand-read.c` | Are the reader programs. `big-read` reads a whole file. `rand-read` reads at random offsets. |
| `Makefile` | Builds `big-read` and `rand-read`. |
| `villain.fio` | Runs 512 random-read jobs against one large file. |
| `sweep-*.sh` (25 files) | Sweep one parameter and collect the metrics. The parameters are the villain count, the victim count, the working set size, the worker count and the kernel version. |
| `hold-slice-compare.sh`, `hold-slice-32g-only.sh` | Run `hold_and_slice.bt` at fixed configurations and compare the histograms. |
| `perf-compare.sh` | Records a perf profile for two configurations. |
| `*.log`, `*.txt` | Hold the recorded results. They are data, not code. |

#### 11.3.4 `sh/em-shrinker-xa-contention/` — the `xa_lock` contention

The bug: `find_first_inode_to_shrink()` holds `root->inodes.xa_lock` for a
whole scheduler time slice. Three paths contend on the same lock: the extent
map shrinker, kswapd and the user-space file churn.

| File | Function |
| --- | --- |
| `standalone-minimal.sh` | Is the self-contained reproducer. |
| `standalone-minimal-share.sh` | Is the short version. Send this file to an external developer. |
| `test-minimal.sh` | Runs the reproducer inside a VM with the trace and the perf record. |
| `run-in-vm.sh` | Runs the full test inside a `vng` VM. Keeps the results in `results/`. |
| `hold-inodes.c` | Makes many files, holds them open, and reads them at random offsets. Keeps `extent_tree.lock` held on many inodes at the same time. |
| `churn.c` | Makes and deletes files quickly. Hammers `btrfs_add_inode_to_root` and `btrfs_del_inode_from_root`. |
| `trace-shrinker.bt` | Measures how long `find_first_inode_to_shrink()` holds the lock. Counts the `cond_resched_lock` calls. |
| `results/` | Holds the recorded output: the bpftrace log, the perf report, the stacks and the run log. |

#### 11.3.5 `sh/writeback-storm/` — the metadata stall feedback loop

The bug: preemptive reclaim picks `FLUSH_DELALLOC`. The COW amplification from
the writeback makes more delayed refs than the flush drains. This is a
positive feedback loop. Unrelated metadata operations then block for seconds
or minutes.

| File | Function |
| --- | --- |
| `standalone-minimal.sh` | Is the self-contained reproducer. |
| `writeback-storm-minimal.sh` | Does the same with the shared libraries. |
| `baby.sh` | Is the smallest version. Uses the root filesystem. Has no `mkfs`, no parallel work and no measurement. |
| `commit_stall_repro.sh` | Forces a commit at a fixed interval during the storm. This makes the commit collide with the reclaim. |
| `reset.sh` | Resets the state between runs. Deletes the work files, balances the empty block groups, resets the clamp and sets the dirty-page tunables. |
| `reset-clamp.py` | Writes the metadata clamp back to 1. Uses the drgn `kmodify` helper. |
| `monitor.sh` | Prints the dirty pages, the writeback pages and the metadata space at a fixed interval. |
| `pipeline-monitor.py` | Takes a snapshot of the reclaim pipeline with drgn: the four pools, the reserve gaps, the rates of change and the `need_preemptive_reclaim` decision. Can print JSON. |
| `commit_oe_burst.bt` | Tests the burst theory. Counts the ordered extent completions inside a commit window and outside it. |
| `preempt_tripwire.bt` | Exits as soon as the preemptive metadata reclaim fires. Use it as a trigger for other tools. |

#### 11.3.6 `sh/reclaim-refcount-bug/` — the block group refcount leak

The bug: the reclaim worker and the relocation code both put the same block
group reference, after relocation hits `ENOSPC` in the cache truncation. The
`README.md` gives the debug printk patch that you need.

| File | Function |
| --- | --- |
| `README.md` | Describes the bug, the debug instrumentation and each script. |
| `standalone-minimal.sh` | Is the self-contained reproducer, 122 lines. |
| `reclaim-refcount-minimal.sh` | Does the same with the shared libraries. |
| `parallel-test.sh` | Adds the file churn workers and the balance operations. |

#### 11.3.7 `sh/squota-inheritance/` — the qgroup leak

The bug: a level 1 qgroup keeps its metadata usage after every member leaves.
It needs a two-level hierarchy and a manual assignment of the intermediate
snapshot.

| File | Function |
| --- | --- |
| `README.md` | Describes the bug pattern in six steps, and each script. |
| `standalone-minimal.sh` | Is the self-contained reproducer, 84 lines. Send this file by mail. |
| `btrfs-squota-bug-minimal.sh` | Does the same with the shared libraries. |
| `parallel-test.sh` | Runs several workers. Each worker makes and destroys a hierarchy again and again. |

#### 11.3.8 `sh/orphan-cleanup-race/` — the orphan cleanup `ENOENT`

The bug: `btrfs_orphan_cleanup()` has a race window between `iput()` and
`btrfs_del_orphan_item()`. Another thread deletes the orphan item in that
window. The cleanup then returns `ENOENT` and makes a permanent negative
dentry for a valid subvolume.

| File | Function |
| --- | --- |
| `README.md` | Describes the race in eight steps. Gives the debug patch, the expected output and the fix. |
| `standalone-reproducer.sh` | Is the reproducer. Needs `dm-delay`, btrfs-progs and Python 3. |
| `standalone-reproducer-v3.sh` | Is the shell-only version. It needs no Python. Takes an attempt count. |

#### 11.3.9 The other reproducers

| Directory | Function |
| --- | --- |
| `sh/append-csum-hole/` | Runs an append loop, a direct read loop, a sync loop and a `drop_caches` loop together on a compressed file. Looks for a checksum hole. |
| `sh/chunk-write-vs-balance/` | Runs a small-file fio loop, a chunked write loop and a balance loop together. Compares the checksum of the written file after each pass. |
| `sh/dev-extent-pending-hole/` | Pushes the block group frontier out, then removes a large gap of block groups. Then it forces the allocations into the gap. |
| `sh/discard-reclaim-race/` | Races the block group reclaim against the asynchronous discard. Has a `discard.bt` that prints the queue, trim, mark and relocate events. |
| `sh/dup_tree_ref/` | Runs `fsstress`, two snapshot threads and eight reflink threads together, on a compressed filesystem. Looks for a duplicate tree ref. |
| `sh/enospc-leak/` | Fills the filesystem, then makes severe fragmentation with 1024 medium files and 1024 small files. Causes `ENOSPC` inside `btrfs_reserve_extent`. |
| `sh/fsync-crash/` | Writes 100000 small files with fio, then fsyncs the first file and the last file at the same time. |
| `sh/parallel-force-chunk-alloc/` | Forces a data chunk allocation and a metadata chunk allocation from two loops at the same time. |
| `sh/parted-vs-mount/` | Makes and removes partitions with `parted` while the device holds a mounted filesystem. |
| `sh/reclaim-infinite/` | Is empty. It is a placeholder for an infinite reclaim loop. |
| `sh/subpage-hole-submit/` | Writes a large file, punches 10000 holes, then fails the writes with the error injection knob. Dumps the extent maps before and after. |

---

### 11.4 The experiment and workload scripts

| Directory | Function |
| --- | --- |
| `sh/atomic-update-loop/` | Runs the `c/atomic-update` program one million times against ext4. Runs `e2fsck` after each pass. |
| `sh/chunk-alloc-wq/` | Fills the filesystem to the last 10 GiB, then allocates five more files at the same time. Sets the reclaim threshold first. |
| `sh/compile-pressure/` | Builds the Linux kernel in a loop on the test filesystem, with `fsstress` beside it. Runs `btrfs check` at the end. |
| `sh/compr-read-perf/` | Compares the read speed of a compressed file and an uncompressed file, at several block sizes. Drops the caches before each read. |
| `sh/dynrec/` | Tests the dynamic reclaim. Makes a 108 GiB file on a compressed filesystem, then turns on the dynamic and periodic reclaim. |
| `sh/extent-tree-v2/` | Makes a filesystem with the `extent-tree-v2` feature, then writes 27 files of 40 MiB. |
| `sh/fstest-results/` | Is the older result tool. Diffs the failures of one run against the latest `for-next` run. `sh/fstests-utils/results/` replaces it. |
| `sh/ino-resolve/` | Makes one million files, then deletes them at random while it resolves logical addresses. Tests the tree modification log. |
| `sh/ns-test/userns/` | Tests btrfs and squota inside a user namespace. Compares the `unshare` mode against the `sudo` mode. |
| `sh/punt-bg/` | Writes a file, deletes it, waits for the cleaner, then remounts with `discard=async`. |
| `sh/qgroup/` | Holds nine qgroup and squota experiments. See the table below. |
| `sh/qgroup-inherit/` | Is a stub. It only does the setup. |
| `sh/reclaim/` | Makes 16 files of 128 MiB, then deletes half of them, to test the reclaim threshold. Has a `reclaim.bt` that prints each `should_reclaim_block_group` decision. |
| `sh/reloc_tree/` | Is empty. It is a placeholder. |
| `sh/seed/` | Makes a btrfs seed device and a sprout device (`mkseed.sh`). Also makes a read-only device and a read-write device (`rodev-seed.sh`). |
| `sh/sharded-trees/` | Makes an `extent-tree-v2` filesystem, then writes 10 files of 40 MiB. |
| `sh/size-class/` | Writes files of three size classes, cycles the mount, then writes one more. Prints the size class state from sysfs. |
| `sh/size-class-vs-cluster/` | Writes a large extent and a medium extent in a loop, on an `ssd_spread` mount. Prints the usage after each pass. |
| `sh/skip-extent-writes/` | Injects write errors at a rate that you set, then repairs the filesystem. Counts the clean mounts, the backup-root mounts, the repairs and the failures. |
| `sh/snap-scale/` | Measures how the snapshots scale. Takes a mode: no quota, quota or squota. Takes a file count and a snapshot count. |
| `sh/snap-share/` | Makes a file, a snapshot and a copy. Reads all three, then unshares the original. Marks each step in `/dev/kmsg`. |
| `sh/strand-meta/` | Puts the shell into a small cgroup with two CPUs, then writes 10000 files. Dumps the folio state and the vmstat counters with drgn. |
| `sh/verity/` | Tests fs-verity on btrfs. `btrfs-verity.sh` corrupts a byte and checks that the execution fails. `send-recv.sh` tests a signed file through send and receive. |

The `sh/qgroup/` experiments:

| File | Function |
| --- | --- |
| `qgroup.sh` | Gives the report helpers. See section 3.1. |
| `simple-snap.sh` | Prints the qgroup usage after each step of a snapshot sequence. |
| `simple-share.sh` | Does the same, but with two snapshots that share the data. |
| `snap-only.sh` | Prints the usage for the snapshot step only, in JSON. |
| `dangle-file.sh` | Deletes the original file and then the snapshot file. Checks the usage after each delete. |
| `dangle-subvol.sh` | Deletes the original subvolume instead of the file. |
| `meta-unshare.sh` | Adds the owned-metadata dump to each step. Shows how the metadata unshares. |
| `reflink.sh` | Makes a reflink copy of a file and checks the usage. |
| `delayed-refs.bt` | Counts the delayed data ref stacks, by action and by owning root. |
| `extent-lifetime.bt` | Follows one extent through `btrfs_record_squota_delta`. Prints the running total per root and per extent. |

---

## 12. How to install the commands

Install one command tree:

```sh
cd sh/vm
make install
```

The `install` target makes the symbolic links in `~/.rcli/clis/vm/`. Then call
the command:

```sh
rcli vm list
rcli vm up v0
rcli fstests-utils test my-branch
```

The `rcli` dispatcher takes the flags itself. To send a long option to a
subcommand, put `--` before it:

```sh
rcli fstests-utils kp -- --branch for-next --window 12
```

Build the C programs:

```sh
cd c && make
cd sh/noisy-neighbor && make
```

Build the Rust tool:

```sh
cd rust/btrfs-frag-view && cargo build --release
```

---

## 13. Conventions

### 13.1 The file names

| Name | Meaning |
| --- | --- |
| `run` | Is an `rcli` subcommand. Has no extension. |
| `run.sh` | Is the entry point of a directory that is not an `rcli` command. |
| `standalone-minimal.sh` | Has no dependencies. Send it to an external developer. |
| `*-minimal.sh` | Is the same test, but it uses the shared libraries. |
| `parallel-test.sh` | Is the stress version, with several workers. |
| `*.bt` | Is a bpftrace script. |
| `*.drgn`, `*.py` in `drgn/` | Is a drgn script. |
| `*.btrd` | Is a btrd script. |
| `*.fio` | Is an fio job file. |

### 13.2 What git ignores

Git does not track these items:

- The output files (`*.out`) and the filesystem images (`*.img`).
- The binaries in `c/`. Git tracks only the `.c`, `.h` and `Makefile` files.
- The Rust `target` directories.
- The `__pycache__` directories and the `.claude` directory.

### 13.3 Safety

Almost every script in `sh/` runs `mkfs` on the device that you give it. The
script deletes all the data on that device.

Use a scratch device only. Do not give a device that holds data that you need.
