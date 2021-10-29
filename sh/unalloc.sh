#!/bin/sh

GB=$((1024 * 1024 * 1024))

# dusage from 30-70
MAX_TRIES=5
DUSAGE_START=30
DUSAGE_STEP=10
BALANCE_LIMIT=5

_unalloc() {
  local mnt=$1
  btrfs fi usage -b $mnt | grep unallocated | cut -d: -f2 | tr -d '\t' | tr -d ' '
}

_meta() {
  local mnt=$1
  btrfs fi usage -b $mnt | grep Metadata | grep Size | cut -d: -f3 | cut -d, -f1
}

_check_mount() {
  local mnt=$1
  findmnt -t btrfs $mnt
}

_uuid() {
  local mnt=$1
  btrfs fi show $mnt | grep uuid: | awk '{print $4}'
}

_force_alloc() {
  local uuid=$1
  echo 1 > /sys/fs/btrfs/$uuid/allocation/metadata/force_chunk_alloc
}

_try_balance() {
  local mnt=$1
  local desired=$2
  local desired_bytes=$(($desired * $GB))
  local tries=0
  local dusage=$DUSAGE_START
  local dlimit=$desired
  local add_to_tier=0

  echo "TRY-BALANCE $mnt $desired_bytes"

  local unalloc=$(_unalloc $mnt)
  local meta=$(_meta $mnt)
  local want=$(($desired_bytes - $meta + $GB))

  while [ $unalloc -lt $want ] && [ $tries -lt $MAX_TRIES ]; do
    echo "unalloc $unalloc less than $want. Balance $mnt with dusage $dusage dlimit $dlimit."
    local start_t=$(date +%s)
    btrfs filesystem balance start -dusage=$dusage,limit=$dlimit $mnt
    local end_t=$(date +%s)
    if [ $((end_t - start_t)) -lt 1 ]; then
      let dlimit+=10
    fi
    let dusage+=10
    let tries+=1
    unalloc=$(_unalloc $mnt)
  done
  echo "TRY-BALANCE-DONE: $mnt $desired_bytes $(_unalloc $mnt) $want"
}

_balance_and_alloc() {
  local mnt=$1
  local desired=$2
  local desired_bytes=$(($desired * $GB))
  local tries=0

  _check_mount $mnt > /dev/null
  if [ $? -ne 0 ]; then
    echo "not a btrfs mount $mnt; skip"
    return
  fi

  local uuid=$(_uuid $mnt)
  local meta=$(_meta $mnt)

  if [ $meta -gt $desired_bytes ]; then
    echo "ENOUGH-META-SKIP $meta"
    return
  fi

  _try_balance $mnt $desired

  while [ $meta -lt $desired_bytes ] && [ $tries -lt $desired ]; do
    _force_alloc $uuid
    meta=$(_meta $mnt)
    let tries+=1
  done

  echo "BALANCE-AND-ALLOC-DONE: $mnt $(_meta $mnt) $desired"
}

_balance_and_alloc / 5
#_balance_and_alloc /data 10
#_balance_and_alloc /data/device00/mount_point 10
