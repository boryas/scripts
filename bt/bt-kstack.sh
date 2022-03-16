#!/bin/sh

if [ "$#" -lt 1 ]
then
	echo "usage: bt-kstack-bt.sh <func>"
	exit 1
fi

sudo bpftrace -e "kprobe:$1 {@[kstack] = count();}"
