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
	\$delay_ns = nsecs - @$fname[tid];
	\$delay_ms = \$delay_ns / 1000000;
	\$cg_name = str(curtask->cgroups->dfl_cgrp->kn->name);
	@$hist_name[\$cg_name] = hist(\$delay_ms);
	@pressure_ns[\$cg_name] += \$delay_ns;
	delete(@$fname[tid]);
}

EOF
}

gen btrfs_start_transaction
gen btrfs_commit_transaction
gen btrfs_reserve_data_bytes
gen btrfs_reserve_metadata_bytes
gen btrfs_start_ordered_extent
