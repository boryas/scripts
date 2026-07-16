# zstd: btrfs compress-force=zstd:3 mount.  Always compresses on the
# buffered write path (no heuristic skip).  DIO writes bypass compression
# entirely on btrfs, so the dio-*write cells are excluded.  DIO reads of
# compressed extents fall back to buffered + decompress, which IS worth
# measuring -- they stay in.
mount_opts=compress-force=zstd:3
compat=buffered-* dio-*read
