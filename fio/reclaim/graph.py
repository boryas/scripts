import matplotlib.pyplot as plt

def as_gb(val):
    if val == 0:
        return 0
    g = 0
    factor = 1
    while g == 0:
        g = ((val * factor) >> 30) / factor
        factor *= 10
    return g

def normalize(stat, val):
    v = int(val)
    if "bytes" in stat:
        return as_gb(v)
    return v

def data_dir(workload, run):
    return f"results/{workload}/{run}"

def get_data(workload, run, stat):
    dir=data_dir(workload, run)
    with open(f"{dir}/{stat}.dat", "r") as f:
        ls = f.readlines()
        return [normalize(stat, v) for v in ls]

def make_plot(stat, runs):
    plt.xlabel("Time (sec)")
    ylabel = f"{stat}"
    if "bytes" in stat:
        ylabel += " (GiB)"
    if "pct" in stat:
        plt.ylim([0, 100])
    plt.ylabel(ylabel)
    for run, data in runs.items():
        time=[t * 5 for t in range(len(data))]
        plt.plot(time, data, label=run, marker=".")
    plt.legend(loc="upper left")

def make_plots(data):
    for workload, stats in data.items():
        for stat, runs in stats.items():
            if not runs:
                continue
            plt.figure()
            make_plot(stat, runs)
            plt.savefig(f"results/{workload}/{stat}.png")

STATS = [
    "unalloc_bytes",
    "unused_bytes",
    "used_bytes",
    "alloc_bytes",
    "reclaims",
    "thresh",
    "alloc_pct",
    "used_pct",
    "unused_unalloc_ratio"
]

RUNS = [
    #"free-0",
    "free-30",
    #"free-50",
    #"free-70",
    "per-30",
    #"per-50",
    #"per-70",
    #"free-dyn",
    "per-dyn",
]

WORKLOADS = [
    "bounce",
    "strict_frag",
    "last_gig",
]

if __name__ == "__main__":
    data = {}
    for workload in WORKLOADS:
        data[workload] = {}
        for stat in STATS:
            data[workload][stat] = {}
            for run in RUNS:
                try:
                    data[workload][stat][run] = get_data(workload, run, stat)
                except FileNotFoundError:
                    continue
    make_plots(data)
