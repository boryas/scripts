import drgn
from drgn import FaultError, NULL, Object, alignof, cast, container_of, execscript, implicit_convert, offsetof, reinterpret, sizeof, search_memory, search_memory_regex, search_memory_u16, search_memory_u32, search_memory_u64, search_memory_word, source_location, stack_trace
from drgn.helpers.common import *
from drgn.helpers.linux import *
from drgn.helpers.experimental.kmodify import write_object

sb = path_lookup(prog, "/").mnt.mnt_sb
fi = cast("struct btrfs_fs_info *", sb.s_fs_info)
for si in list_for_each_entry("struct btrfs_space_info", fi.space_info.address_of_(), "list"):
    if si.flags & 0x4:
        print(f"clamp: {si.clamp.value_()} -> 1")
        write_object(si.clamp, 1)
