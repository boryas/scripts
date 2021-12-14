#!/bin/sh

STREAM=$1
grep -v probes $STREAM | sort -n | awk '{print $2 " " $3 " " $4 " " $5}'
