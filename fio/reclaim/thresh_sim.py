#!/usr/bin/python3

DISK_SIZES = range(100, 1001, 100)

def clamp(val, lo, hi):
    if val < lo:
        return lo
    if val > hi:
        return hi
    return val

class Disk:
    def __init__(self, size):
        self.size = size
        self.alloc = 0
        self.used = 0
        self.reclaim_count = 0

    def __repr__(self):
        return f"Disk(size {self.size} alloc {self.alloc} used {self.used} unalloc {self.size - self.alloc} unused {self.alloc - self.used})"

    def use(self, size):
        if self.alloc + size > self.size:
            raise RuntimeError("ENOSPC!!!")
        self.alloc += size
        self.used += size

    def free(self, size):
        if self.used < size:
            raise RuntimeError("free underflow!!!")
        self.used -= size

    def reclaim_one(self):
        if self.alloc == 0:
            raise RuntimeError("reclaim underflow!!!")
        self.alloc -= 1
        self.reclaim_count += 1

    def calc_unalloc_target(self):
        return clamp(self.size * 0.05, 1, 5)

    def calc_thresh(self):
        alloc = self.alloc
        unused = self.alloc - self.used
        unalloc = self.size - alloc
        target = self.calc_unalloc_target()
        want = max(0, target - unalloc)
        left = max(0, unused - want)
        can = 1 if unused > 0 else 0
        raw = (can * want) / target
        clamped = clamp(raw, 0, 1)
        print(f"calc thresh {self} want {want} target {target} left {left} can {can} raw {raw} clamped {clamped}")
        return clamped

    # Assumes average spread; not necessarily true
    def would_reclaim(self):
        thresh = self.calc_thresh()
        alloc = max(self.alloc, 1)
        usage = self.used / alloc
        print(f"would reclaim? {self} avg usage {usage} thresh {thresh} {usage < thresh}")
        return usage < thresh

    def simulate_reclaims(self):
        while self.would_reclaim():
            self.reclaim_one()

def calc_all_threshes():
    for disk in DISK_SIZES:
        disk_step = max(1, int(disk / 20))
        for alloc in range(0, disk + 1, disk_step):
            alloc_step = max(1, int(alloc / 10))
            for used in range(0, alloc + 1, alloc_step):
                thresh = calc_thresh(disk, alloc, used)
                print(f"disk {disk} alloc {alloc} used {used} thresh {thresh}")

if __name__ == "__main__":
    d = Disk(10)
    d.use(10)
    d.free(5)
    d.simulate_reclaims()
    print(f"{d} reclaims: {d.reclaim_count}")
