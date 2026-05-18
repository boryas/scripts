# fstests-utils infrastructure notes

Things that took non-trivial investigation to figure out, that aren't
otherwise documented. Read this if you're picking the pipeline back up
after a break, or onboarding someone else (or yourself, future me).

## Pipeline shape

```
workstation:              fstests cloud worker (ephemeral):     s1 (sfo3):
  ~/repos/linux-fnext       /mnt/repos/fstests                    /usr/local/share/
  cron/for-next                fstests check                        site/static/html/
  test/run             ssh   para-fstests/ssh-one.sh                  fstests/      <- nginx
   build kernel  --->     run tests, ship results back        ^         |
   provision workers  ---  on shutdown, droplets torn down    |         | rsync
   para-fstests dispatch -                                    |         v
   digest, state                                              |    /mnt/fstests_data/
   publish  ---------------------- rsync digests + scripts -->     results/       <- Volume
                                   ssh trigger html/run             history.json
```

Three co-evolved repos: `cloud-fstests` (worker provisioning), `para-fstests`
(dispatcher), and `scripts/sh/fstests-utils` (this dir: orchestration + digest
+ HTML + cron). They live in separate repos but are tightly coupled and
typically evolve together.

## DigitalOcean

- `doctl compute droplet list` -- the subcommand is `compute droplet`, **not**
  `droplet`. `doctl droplet list` errors with "unknown command".
- `doctl compute volume list` for volumes.

### s1 (the always-on host serving bur.io)

- Droplet ID `291063825`, region `sfo3`, size `s-1vcpu-1gb` (small!), Fedora 35.
- DO Volume `fstests-data` (1 GiB, ID `9c9eb435-50a8-11f1-ab86-0a58ac120b98`)
  attached. Auto-mounted at `/mnt/fstests_data` (ext4) by a DO-generated
  systemd unit `mnt-fstests_data.mount` -- no fstab entry needed, survives reboots.
- `~/fstests-results -> /mnt/fstests_data/results` (symlink). Volume holds the
  canonical digest tree + history.json + .details/ artifacts.
- Nginx serves HTML from `/usr/local/share/site/static/html/fstests/` -- this is
  on the **root disk** (`/dev/vda4`), not the Volume. HTML is derivative; data
  on the Volume is the source of truth.
- `bo` user on s1 has no github SSH key. Update s1's copy of fstests-utils by
  rsync from workstation, not `git pull`. The publish flow does this automatically.
- sudo over batched ssh fails ("a terminal is required") -- no TTY allocation.
  For one-off privileged work, ask the user to run the sudo command interactively.

### Cloud workers (ephemeral fstests workers)

- Created from snapshot ID `228498757`, SSH key ID `56292933`.
  Defaults in `cloud-fstests/workers/cloud/config.sh`.
- Default region `nyc3`, size `s-2vcpu-4gb`, `N=10` per `workers/cloud/up`
  invocation. Override with `N=1` for one-shot debugging.
- `workers/cloud/up` writes ssh targets to `/tmp/fstests-cloud-workers/hosts`
  (one `fstests@<ip>` per line).
- `workers/cloud/down` deletes by tag (the run-specific tag from `up`).
- Workers' root fs is **btrfs** with `compress=zstd:1`. This matters: when test
  scratch is loop-backed on this root, you get btrfs-on-btrfs which can change
  test outcomes (see generic/301 in KNOWN_FAILURES).
- Loop devices `loop0`..`loop6` backed by `/home/fstests/loops/d*.img`.
  `fstests-loops.service` re-mkfs's only `/dev/loop0` (TEST_DEV) per boot;
  loops 1-6 retain whatever the snapshot was captured with. **Some loops in
  the snapshot have stale btrfs signatures** -- check with `wipefs -n /dev/loop*`
  if you see weird "found more devices" messages from btrfs-progs.
- fstests lives at `/home/fstests/fstests/` with a symlink at `/mnt/repos/fstests`.
- Distro btrfs-progs is `v6.17-1.fc43` (`/usr/bin/btrfs`). This is **newer
  than v0's custom build** (`/mnt/repos/btrfs-progs/btrfs`), which has caused
  tooling-skew test failures (see btrfs/218 in KNOWN_FAILURES). Either
  upgrade v0 or downgrade the cloud snapshot to keep behavior consistent.

## Publish flow (workstation -> s1)

`rcli fstests-utils publish <branch>` is a thin wrapper around three steps:
1. rsync `~/repos/scripts/sh/fstests-utils/` -> `s1:~/repos/scripts/sh/fstests-utils/`
2. rsync `~/fstests-results/<branch>/` -> `s1:~/fstests-results/<branch>/`
3. ssh s1 to invoke `~/repos/scripts/sh/fstests-utils/html/run` with
   `HTML_DIR=/usr/local/share/site/static/html/fstests`

`test/run` calls this as its final step, so every finished run lands on bur.io
automatically. No s1 cron involved -- workstation drives the trigger, so there's
no race between rsync and render.

## Cron

- Daily `fstests-for-next.service` at 00:00 PDT (`fstests-for-next.timer`),
  installed at `~/.config/systemd/user/`.
- The cron script (`cron/for-next`) operates on a detached worktree
  `~/repos/linux-fnext` so it doesn't touch the user's main repo. `git fetch
  btrfs` then `git checkout --detach btrfs/for-next`.
- `test/run`'s checkout logic only swaps HEAD if HEAD is *attached* to a
  branch. If HEAD is already detached (the cron's case), it's left alone --
  avoids the bug where a stale local `for-next` branch tip would override the
  cron's intended commit.

## KNOWN_FAILURES.yaml

Source of truth for tests that fail persistently on this setup. `html/run`
reads it and: drops listed bad-verdict tests from the headline fail/hang
counts, renders them in a "known" bucket grouped by `category`, and surfaces
"transitioned" tests (listed test produced pass/skip/flake this run) in a
green callout for demotion review.

Schema (one entry per test):
```yaml
- test: <group>/<num>
  category: enospc-fragility | dm-suspected-real | tooling-skew |
            env-fixed-pending-verify
  status:   known-test-bug | needs-upstream-check |
            fixed-pending-verify | tooling-skew
  explanation: |
    Multi-line. What's known about the failure mode.
  investigated: YYYY-MM-DD
  refs:
    - commit: <sha>
    - upstream: <url>
```

Add a test after >= 3 consecutive same-cause failures. Remove (or change
status to `fixed-upstream`) once resolved.

Related lists in this dir (different semantics):
- `PARA_SKIP` -- skip in parallel phase, run in retry only (slow tests).
- `PERSISTENT_HANGS` -- don't run at all (hangs past 30m retry budget).

## rcli quirks

- Source at `~/repos/clitools/`. C binary at `~/.local/bin/rcli`.
- Install (`make install`) touches `.zshenv` and `.zshrc`. Headless servers
  without zsh get weird config files written. Avoid installing on s1.
- Bypass on hosts without rcli: invoke the script path directly,
  e.g. `~/repos/scripts/sh/fstests-utils/html/run`. `html/run` has no internal
  `rcli` calls so this works for the s1 render path.
- Internal `rcli` calls exist in `test/run`, `cron/for-next`, `backfill/run`,
  and the `workers/local-vm/` shims. If you want to drop the rcli dependency
  on a host that runs these, replace each `rcli fstests-utils X` with a direct
  path or build rcli on that host.

## Workstation gotchas

- `jq` is **not installed** -- use python3 for JSON wrangling.
- Workstation's `~/repos/linux` is the user's working repo. The cron uses
  `~/repos/linux-fnext` (a separate worktree, also detached HEAD) to avoid
  conflicting with the user's branch checkout. Both share the same object
  store; cost is just disk for the checkout dir + build artifacts.

## Verification paths

- Live site: `https://bur.io/fstests/for-next/`
- s1 HTML dir: `/usr/local/share/site/static/html/fstests/`
- s1 data dir: `/mnt/fstests_data/results/` (aka `~/fstests-results/` via symlink)
- Workstation data dir: `~/fstests-results/<branch>/`
- Run digest: `~/fstests-results/<branch>/<run_id>.json` (run_id = `<short_sha>-<UTC_timestamp>`)
- History: `~/fstests-results/<branch>/history.json`
