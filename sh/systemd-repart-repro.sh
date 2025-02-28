#!/usr/bin/env bash

mkdir /tmp/repro
cd /tmp/repro
cat >root.conf <<EOF
[Partition]
Type=root
Format=btrfs
EOF

systemd-repart --empty=create --size=auto --definitions . abc
unshare -m systemd-repart --image abc abc
