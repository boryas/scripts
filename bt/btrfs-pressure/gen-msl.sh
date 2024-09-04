#!/usr/bin/env bash

gen() {
    local fname=$1
    local hist_name=$fname"_ms_hist"

    cat <<EOF
kfunc:$fname {
	@$fname[tid] = nsecs;
}

kretfunc:$fname {
	if (!@$fname[tid]) {
		return;
	}
	\$now_ns = nsecs;
	\$delay_ns = \$now_ns - @$fname[tid];
	\$tup = (\$now_ns, "$fname", \$delay_ns, "_sl_comm", comm, cgroup_path(cgroup), "_sl_ustack", ustack(raw), "_sl_kstack", kstack(raw));
	print(\$tup);
	delete(@$fname[tid]);
}

EOF
}

gen btrfs_start_transaction
gen btrfs_commit_transaction
gen btrfs_reserve_data_bytes
gen btrfs_reserve_metadata_bytes
gen btrfs_start_ordered_extent
