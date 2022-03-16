#!/bin/sh

if [ "$#" -lt 1 ]
then
	echo "usage: bt-timing-hist.sh <func>"
	exit 1
fi

kprobe="kprobe:$1 { @start[tid] = nsecs; }"
kretprobe="kretprobe:$1 { \
	if(@start[tid]) { \
		\$delta = nsecs - @start[tid]; \
		@nsecs = hist(\$delta); \
		delete(@start[tid]); \
	} }"
sudo bpftrace -e "$kprobe $kretprobe"
