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

def get_data(run, stat):
    with open(f"{run}/{stat}.dat", "r") as f:
        ls = f.readlines()
        return [normalize(stat, v) for v in ls]

def make_plot(stat, runs):
    plt.xlabel("Time (sec)")
    ylabel = f"{stat}"
    if "bytes" in stat:
        ylabel += " (GiB)"
    plt.ylabel(ylabel)
    for run, data in runs.items():
        data = data[14:]
        time=[t * 5 for t in range(len(data))]
        plt.plot(time, data, label=run, marker=".")
    plt.legend(loc="upper left")

def make_plots(data):
    for stat, runs in data.items():
        plt.figure()
        make_plot(stat, runs)
        plt.savefig(f"{stat}.png")

STATS = [
    "unalloc_bytes",
    "unused_bytes",
    "used_bytes",
    "alloc_bytes",
    "relocs",
    "thresh",
    "alloc_pct",
    "used_pct",
    "unused_unalloc_ratio"
]

RUNS = [
    #"free-0",
    "free-30",
    "free-50",
    "free-70",
    #"per-30",
    "per-50",
    "per-70",
    "free-dyn",
    "per-dyn",
]

if __name__ == "__main__":
    data = {}
    for stat in STATS:
        data[stat] = {}
        for run in RUNS:
            try:
                data[stat][run] = get_data(run, stat)
            except FileNotFoundError:
                continue
    make_plots(data)
