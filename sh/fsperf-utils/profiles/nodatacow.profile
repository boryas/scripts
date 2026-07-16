# nodatacow: btrfs nodatacow mount.  Disables COW + checksums.
# Effect on writes: extents allocated once, overwritten in place.
# Effect on reads: csum verification is skipped.
mount_opts=nodatacow
compat=*
