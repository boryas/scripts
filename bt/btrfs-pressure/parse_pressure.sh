#!/usr/bin/env bash

get_cgroup() {
	find /sys/fs/cgroup -inum $1 | grep . || echo "$1"
}

ns_to_ms() {
	echo $(($1 / 1000000))
}

pressure_lines=$(cat btrfspressure.out | grep pressure_ns)
cgroups=$(echo "$pressure_lines" | sed -r 's/.*\[(.*)\].*/\1/' | xargs -I{} bash -c 'find /sys/fs/cgroup -inum {} | grep "/" || echo "{}"')
pressures=$(echo "$pressure_lines" | cut -d' ' -f2 | xargs -I{} bash -c 'echo $(({} / 1000000))')

paste <(echo "$cgroups") <(echo "$pressures")
