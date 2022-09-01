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
		@z_nsecs = hist(\$delta); \
		@y_usecs = lhist(\$delta / 1000, 0, 1000, 100);
		@x_msecs = lhist(\$delta / 1000000, 0, 1000, 50); \
		delete(@start[tid]); \
	} }"
sudo bpftrace -e "$kprobe $kretprobe"
