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
	\$delay_ms = \$delay_ns / 1000000;
	printf("%llu %llu %llu, %s, %s, %s\n", \$now_ns, \$delay_ns, \$delay_ms, comm, cgroup_path(cgroup), kstack);
	delete(@$fname[tid]);
}

EOF
}

gen btrfs_start_transaction
gen btrfs_commit_transaction
gen btrfs_reserve_data_bytes
gen btrfs_reserve_metadata_bytes
gen btrfs_start_ordered_extent
