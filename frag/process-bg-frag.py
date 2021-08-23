import collections
import statistics
import sys

SHARED_EXTENT = "EXTENT-SHARED-REF"
NORMAL_EXTENT = "EXTENT-RESOLVED-REF"
FREE = "FREE"
BG_DONE = "BG-DONE"

class SharedExtent:
    def __init__(self, bg, off, l, ref_off):
        self.bg = bg
        self.off = off
        self.len = l
        self.ref_off = ref_off;
    def owner(self):
        return f"{self.ref_off}"

class NormalExtent:
    def __init__(self, bg, off, l, tree, ino, file_off):
        self.bg = bg
        self.off = off
        self.len = l
        self.tree = tree
        self.ino = ino
        self.file_off = file_off
    def owner(self):
        return f"{self.tree}:{self.ino}"

class ContiguousUsed:
    def __init__(self, first_extent):
        self.bg = first_extent.bg;
        self.off = first_extent.off
        self.extents = []
        self.len = 0
        self.owners = set()

    def add_extent(self, extent):
        self.extents.append(extent)
        self.owners.add(extent.owner())
        self.len += extent.len
        extent.contig = self.id()

    def id(self):
        return f"{self.bg}:{self.off}"

    def __repr__(self):
        return f"CONTIG({self.bg},{self.off},{self.len})"

class FreeExtent:
    def __init__(self, bg, off, l):
        self.bg = bg
        self.off = off
        self.len = l

def compute_hist(vals):
    hist = {}
    step = 4096
    hist[step] = 0
    for val in vals:
        while step < val:
            step *= 2
            hist[step] = 0
        hist[step] += 1
    return hist

class BlockGroup:
    def __init__(self, start):
        self.start = start
        # computed as we add extents
        self.max_free = 0
        self.free_extents = []
        self.extents = []
        self.contigs = []
        self.off = 0
        self.free = 0
        self.contig = None

    def add_shared(self, shared):
        if not self.contig:
            self.contig = ContiguousUsed(shared)
        self.contig.add_extent(shared)
        self.off += shared.len
        self.extents.append(shared)

    def add_normal(self, normal):
        if not self.contig:
            self.contig = ContiguousUsed(normal)
        self.contig.add_extent(normal)
        self.off += normal.len
        self.extents.append(normal)

    def add_free(self, free):
        if self.contig:
            self.contigs.append(self.contig)
            self.contig = None
        self.off += free.len
        self.free += free.len
        if free.len > self.max_free:
            self.max_free = free.len
        self.free_extents.append(free)

    def finish(self):
        self.len = self.off
        self.used = self.len - self.free
        self.num_extents = len(self.extents)
        self.avg_extent = 0
        if (self.num_extents > 0):
            self.avg_extent = int(self.used / self.num_extents)
        if self.contig:
            self.contigs.append(self.contig)
        self.compute_contig_stats()
        self.compute_free_stats()

    def compute_free_stats(self):
        self.avg_free = 0
        self.num_free = len(self.free_extents)
        if (self.num_free > 0):
            self.avg_free = int(self.free / self.num_free)
        self.free_pct = 0
        if (self.len > 0):
            self.free_pct = int(100 * self.free / self.len)
        self.frag_pct = 0
        if (self.free > 0):
            self.frag_pct = int(100 * (1 - (self.max_free / self.free)))
        self.free_lens = sorted([free.len for free in self.free_extents])
        self.free_hist = compute_hist(self.free_lens)

    def compute_contig_stats(self):
        self.num_contigs = len(self.contigs)
        self.contig_num_owners = [len(contig.owners) for contig in self.contigs]
        self.contig_lens = sorted([contig.len for contig in self.contigs])

        self.avg_contig = 0
        if self.num_contigs > 0:
            self.avg_contig = int(sum(self.contig_lens) / self.num_contigs)
            self.avg_contig_owners = int(sum(self.contig_num_owners) / self.num_contigs)


        hist = {}
        contig_cdf = {}
        contig_pdf = {}
        contig_cdf_pct = {}
        contig_pdf_pct = {}
        step = 4096
        hist[step] = 0
        contig_cdf[step] = 0
        contig_pdf[step] = 0
        for contig_len in self.contig_lens:
            while step < contig_len:
                contig_cdf[step * 2] = contig_cdf[step]
                step *= 2
                hist[step] = 0
                contig_pdf[step] = 0
            hist[step] += 1
            contig_cdf[step] += contig_len
            contig_pdf[step] += contig_len
        for step, size in contig_cdf.items():
            contig_cdf_pct[step] = int(100 * (size / self.len))
        for step, size in contig_pdf.items():
            contig_pdf_pct[step] = int(100 * (size / self.len))
        self.contig_hist = hist
        self.contig_cdf = contig_cdf_pct
        self.contig_pdf = contig_pdf_pct

    def __repr__(self):
        return f'{self.start} {self.len} {self.free} {self.num_free} {self.avg_free} {self.used} {self.num_extents} {self.avg_extent} {self.num_contigs} {self.avg_contig} {100 - self.free_pct} {self.free_pct} {self.frag_pct}'

class ExtentOwner:
    def __init__(self, iden):
        self.id = iden
        self.bgs = set()
        self.contigs = set()
        self.lens = []

    def add_extent(self, extent):
        self.lens.append(extent.len)
        self.bgs.add(extent.bg)
        self.contigs.add(extent.contig)

    def num_extents(self):
        return len(self.lens)

    def __repr__(self):
        num_extents = self.num_extents()
        num_bgs = len(self.bgs)
        num_contigs = len(self.contigs)
        bg_count_avg = round(num_extents / num_bgs, 2)
        contig_count_avg = round(num_extents / num_contigs, 2)
        len_avg = round(sum(self.lens) / num_extents, 2)
        len_dist = statistics.quantiles(sorted(self.lens), n=4)
        return f'{self.id} {num_extents} {num_bgs} {bg_count_avg} {num_contigs} {contig_count_avg} {len_avg} {len_dist}'

def process_frag_line(bgs, line):
    cols = line.split()
    line_type = cols[0]
    bg_start = int(cols[1])
    off = int(cols[2])
    l = int(cols[3])

    if bg_start not in bgs:
        bgs[bg_start] = BlockGroup(bg_start)
    bg = bgs[bg_start]
    last_bg = bg

    if (line_type == SHARED_EXTENT):
        ref_off = int(cols[4])
        bg.add_shared(SharedExtent(bg_start, off, l, ref_off))
    elif (line_type == NORMAL_EXTENT):
        tree = int(cols[4])
        ino = int(cols[5])
        file_off = int(cols[6])
        bg.add_normal(NormalExtent(bg_start, off, l, tree, ino, file_off))
    elif (line_type == FREE):
        bg.add_free(FreeExtent(bg_start, off, l))
    elif (line_type == BG_DONE):
        bg.finish()

def process_frag_lines(lines):
    bgs = {}
    for line in lines:
        process_frag_line(bgs, line)
    return bgs

def process_frag(frag_file):
    with open(frag_file, 'r') as f:
        bgs = process_frag_lines(f.readlines())
        owners = {}
        for bg in bgs.values():
            #print(bg)
            #print(bg.contig_hist)
            #print(bg.contig_cdf)
            #print(bg.contig_pdf)
            print(bg)
            print(bg.free_hist)
            continue
            for extent in bg.extents:
                iden = extent.owner()
                if iden not in owners:
                    owners[iden] = ExtentOwner(iden)
                owners[iden].add_extent(extent)
        owners = sorted(owners.items(), key=lambda kv: kv[1].num_extents())
        #for owner in owners[-50:]:
            #print(owner[1])

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("USAGE: process-bg-frag.py <bg-frag.out>")
        exit(1)
    process_frag(sys.argv[1])
