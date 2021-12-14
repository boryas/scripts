extern crate image;

/*
TODO:
[x] decide structure (std::collections::BTreeMap)
[ ] read dump from btrd into structure
[ ] read one alloc from bpftrace into changing structure
[ ] "draw" allocation into an imgbuf
[x] render imgbuf
[ ] collection of images (or imgbufs) into animation
*/

use core::ops::{Deref, DerefMut};
use image::{ImageBuffer, Pixel, Rgb, RgbImage};
use std::collections::{BTreeMap, HashSet};
use std::collections::Bound::{Included, Unbounded};
use std::fs;

const K: u64 = 1 << 10;
const M: u64 = 1 << 20;
const G: u64 = 1 << 30;
const BLOCK: u64 = 4 * K;

const WHITE_PIXEL: Rgb<u8> = Rgb([255, 255, 255]);
const RED_PIXEL: Rgb<u8> = Rgb([255, 0, 0]);

#[derive(Debug, Hash, Eq, PartialEq)]
enum ExtentType {
    Data,
    Metadata
}
#[derive(Debug, PartialEq)]
enum AllocType {
    BlockGroup,
    Extent(ExtentType)
}

// TODO Resultify
impl AllocType {
    fn from_str(type_str: &str) -> Self {
        if type_str == "BLOCK-GROUP" {
            AllocType::BlockGroup
        } else if type_str == "METADATA-EXTENT" {
            AllocType::Extent(ExtentType::Metadata)
        } else {
            AllocType::Extent(ExtentType::Data)
        }
    }
}

#[derive(Debug, PartialEq)]
struct AllocId {
    alloc_type: AllocType,
    offset: u64,
}

#[derive(Debug, PartialEq)]
enum AllocChange {
    Insert(AllocId, u64),
    Delete(AllocId),
}

// TODO Resultify
impl AllocChange {
    fn from_dump(dump_line: &str) -> Self {
        let vec: Vec<&str> = dump_line.split(" ").collect();
        let change_str = vec[0];
        let type_str = vec[1];
        let alloc_type = AllocType::from_str(type_str);
        let offset: u64 = vec[2].parse().unwrap();
        let eid = AllocId { alloc_type, offset };
        if change_str == "INS" {
            let len: u64 = vec[3].parse().unwrap();
            AllocChange::Insert(eid, len)
        } else if change_str == "DEL" {
            AllocChange::Delete(eid)
        } else {
            panic!("bogus extent change dump '{}'", dump_line);
        }
    }
}

#[derive(Debug)]
struct BlockGroupFragmentation {
    len: u64, // block group len
    total_free: u64, // sum of all free extents
    max_free: u64, // largest free extent
}

impl BlockGroupFragmentation {
    fn new(len: u64) -> Self {
        Self { len: len, total_free: 0, max_free: 0 }
    }
    fn add_free(&mut self, len: u64) {
        self.total_free = self.total_free + len;
        if len > self.max_free {
            self.max_free = len;
        }
    }
    fn percentage(&self) -> f64 {
        100.0 * (1.0 - ((self.max_free as f64) / (self.total_free as f64)))
    }
}

#[derive(Debug)]
struct BlockGroup {
    offset: u64,
    len: u64,
    extents: BTreeMap<u64, u64>,
    extent_types: HashSet<ExtentType>,
    img: RgbImage,
    dump: bool,
    dump_count: usize,
}

fn bg_dim(bg_len: u64) -> u32 {
    let block_len = byte_to_block(bg_len);
    (block_len as f64).sqrt().ceil() as u32
}

fn bg_block_to_coord(dim: u32, block_offset: u64) -> (u32, u32) {
    let x = block_offset % dim as u64;
    let y = block_offset / dim as u64;
    (x as u32, y as u32)
}

fn global_to_bg(bg_start: u64, offset: u64) -> u64 {
    offset - bg_start
}

fn byte_to_block(offset: u64) -> u64 {
    offset / BLOCK
}

// RUST BS:
// illegal double borrow for:
// for ext in self.extents { // immutable borrow
//   self.draw_extent(ext) // mutable borrow, doesn't touch extents
// }
// to fix it without adding a copy, need to pull out this free function
fn draw_extent<P, C>(
    img: &mut ImageBuffer<P, C>,
    bg_start: u64,
    extent_offset: u64,
    extent_len: u64,
    dim: u32,
    pixel: P,
) where
    P: Pixel + 'static,
    C: Deref<Target = [P::Subpixel]> + DerefMut,
{
    let ext_bg_off = global_to_bg(bg_start, extent_offset);
    let ext_block_bg_off = byte_to_block(ext_bg_off);
    let nr_blocks = byte_to_block(extent_len);
    let ext_block_bg_end = ext_block_bg_off + nr_blocks;
    for bg_block in ext_block_bg_off..ext_block_bg_end {
        let (x, y) = bg_block_to_coord(dim, bg_block);
        img.put_pixel(x, y, pixel);
    }
}

impl BlockGroup {
    fn new(offset: u64, len: u64, dump: bool) -> Self {
        let dim = bg_dim(len);
        BlockGroup {
            offset: offset,
            len: len,
            extent_types: HashSet::new(),
            extents: BTreeMap::new(),
            img: ImageBuffer::from_pixel(dim, dim, WHITE_PIXEL),
            dump: dump,
            dump_count: 0,
        }
    }

    fn ins_extent(&mut self, offset: u64, len: u64) {
        if offset < self.offset {
            panic!("bad extent! starts before BG {} {} {} {}", self.offset, self.len, offset, len);
        }
        if offset + len > self.offset + self.len {
            panic!("bad extent! ends after BG {} {} {} {}", self.offset, self.len, offset, len);
        }
        self.extents.insert(offset, len);
        self.draw_extent(offset, len, RED_PIXEL);
        if self.dump {
            self.dump_next();
        }
    }

    fn del_extent(&mut self, offset: u64) {
        let extent = self.extents.remove(&offset);
        match extent {
            Some(len) => {
                self.draw_extent(offset, len, WHITE_PIXEL);
                if self.dump {
                    self.dump_next();
                }
            },
            None => {
                println!("bg {} cannot del {}, missing.", self.offset, offset);
            }
        }
    }

    fn fragmentation(&self) -> BlockGroupFragmentation {
        let mut bg_frag = BlockGroupFragmentation::new(self.len);
        let mut last_extent_end = self.offset;
        for (off, len) in &self.extents {
            if *off > last_extent_end {
                let free_len = off - last_extent_end;
                bg_frag.add_free(free_len);
            }
            last_extent_end = off + len;
        }
        let bg_end = self.offset + self.len;
        if last_extent_end < bg_end {
            let free_len = bg_end - last_extent_end;
            bg_frag.add_free(free_len);
        }
        bg_frag
    }

    fn draw_extent(&mut self, extent_offset: u64, len: u64, pixel: Rgb<u8>) {
        let dim = bg_dim(self.len);
        draw_extent(&mut self.img, self.offset, extent_offset, len, dim, pixel)
    }

    fn name(&self) -> String {
        let types: Vec<String> = self.extent_types.iter().map(|et| format!("{:?}", et)).collect();
        let type_names = if types.is_empty() { String::from("Empty") } else { types.join("-") };
        format!("{}-{}", type_names, self.offset)
    }

    fn dump_next(&mut self) {
        let f = format!("{}", self.dump_count);
        self.dump_img(&f);
        self.dump_count = self.dump_count + 1;
    }

    fn dump_img(&self, f: &str) {
        let d = self.name();
        if d.contains("Meta") {
            return;
        }
        let x = fs::create_dir_all(&d);
        let path = format!("{}/{}.png", d, f);
        self.img.save(path).unwrap();
    }
}

#[derive(Debug)]
struct SpaceInfo {
    block_groups: BTreeMap<u64, BlockGroup>,
    dump: bool,
}

impl SpaceInfo {
    fn new() -> Self {
        SpaceInfo {
            block_groups: BTreeMap::new(),
            dump: false,
        }
    }
    fn ins_block_group(&mut self, offset: u64, len: u64) {
        self.block_groups
            .insert(offset, BlockGroup::new(offset, len, self.dump));
    }
    fn del_block_group(&mut self, offset: u64) {
        self.block_groups.remove(&offset);
    }
    fn find_block_group(&mut self, offset: u64) -> Option<&mut BlockGroup> {
        let r = self.block_groups.range_mut((Unbounded, Included(offset)));
        // TODO check that size covers our extent
        match r.last() {
            Some((_, bg)) => Some(bg),
            None => None,
        }
    }
    // TODO errors when no bg exists?
    fn ins_extent(&mut self, extent_type: ExtentType, offset: u64, len: u64) {
        let offset = offset;
        let bg = self.find_block_group(offset).unwrap();
        //println!("insert extent {} {} {} {} {:?}", bg.offset, bg.len, offset, len, extent_type);
        bg.ins_extent(offset, len);
        bg.extent_types.insert(extent_type);
    }
    fn del_extent(&mut self, offset: u64) {
        let bg = self.find_block_group(offset).unwrap();
        bg.del_extent(offset);
    }

    fn handle_alloc_change(&mut self, alloc_change: AllocChange) {
        match alloc_change {
            AllocChange::Insert(AllocId { alloc_type, offset }, len) => match alloc_type {
                AllocType::BlockGroup => {
                    self.ins_block_group(offset, len);
                }
                AllocType::Extent(extent_type) => {
                    self.ins_extent(extent_type, offset, len);
                }
            },
            AllocChange::Delete(AllocId { alloc_type, offset }) => match alloc_type {
                AllocType::BlockGroup => {
                    self.del_block_group(offset);
                }
                _ => {
                    self.del_extent(offset);
                }
            },
        }
    }

    fn toggle_dump(&mut self) {
        self.dump = !self.dump;
        for (_, bg) in &mut self.block_groups {
            bg.dump = self.dump;
        }
    }

    fn dump_imgs(&self, name: &str) {
        for (_, bg) in &self.block_groups {
            bg.dump_img(name);
        }
    }

    fn handle_file(&mut self, filename: &str) {
        let contents = fs::read_to_string(filename).unwrap();
        for line in contents.split("\n") {
            if line.is_empty() {
                continue;
            }
            let ac = AllocChange::from_dump(line);
            self.handle_alloc_change(ac);
        }
    }
}

fn main() {
    let mut si = SpaceInfo::new();
    /*
    si.handle_file("init.txt");
    si.dump_imgs("00-init");
    println!("INIT FRAG");
    for (_, bg) in &si.block_groups {
        let frag = bg.fragmentation();
        println!("{}: {} {:?}", bg.name(), frag.percentage(), frag);
    }
    si.toggle_dump();
    si.handle_file("stream.txt");
    println!("FINAL FRAG");
    for (_, bg) in &si.block_groups {
        let frag = bg.fragmentation();
        println!("{}: {} {:?}", bg.name(), frag.percentage(), frag);
    }
    */
    si.handle_file("final.txt");
    si.dump_imgs("final");
}

#[cfg(test)]
mod test {
    use super::*;
    #[test]
    fn parse_dump_lines() {
        let dummy_dump_line = "INS BLOCK-GROUP 420 42";
        let ac = AllocChange::from_dump(dummy_dump_line);
        assert_eq!(
            ac,
            AllocChange::Insert(
                AllocId {
                    alloc_type: AllocType::BlockGroup,
                    offset: 420
                },
                42
            )
        );

        let dummy_dump_line = "DEL BLOCK-GROUP 420";
        let ac = AllocChange::from_dump(dummy_dump_line);
        assert_eq!(
            ac,
            AllocChange::Delete(AllocId {
                alloc_type: AllocType::BlockGroup,
                offset: 420
            })
        );

        let dummy_dump_line = "INS DATA-EXTENT 420 42";
        let ac = AllocChange::from_dump(dummy_dump_line);
        assert_eq!(
            ac,
            AllocChange::Insert(
                AllocId {
                    alloc_type: AllocType::Data,
                    offset: 420
                },
                42
            )
        );

        let dummy_dump_line = "DEL DATA-EXTENT 420";
        let ac = AllocChange::from_dump(dummy_dump_line);
        assert_eq!(
            ac,
            AllocChange::Delete(AllocId {
                alloc_type: AllocType::Data,
                offset: 420
            })
        );

        let dummy_dump_line = "INS METADATA-EXTENT 420 42";
        let ac = AllocChange::from_dump(dummy_dump_line);
        assert_eq!(
            ac,
            AllocChange::Insert(
                AllocId {
                    alloc_type: AllocType::Extent(ExtentType::Metadata),
                    offset: 420
                },
                42
            )
        );

        let dummy_dump_line = "DEL METADATA-EXTENT 420";
        let ac = AllocChange::from_dump(dummy_dump_line);
        assert_eq!(
            ac,
            AllocChange::Delete(AllocId {
                alloc_type: AllocType::Extent(ExtentType::Metadata),
                offset: 420
            })
        );
    }
    #[test]
    fn ins_extents() {
        let mut si = SpaceInfo::new();
        si.ins_block_group(G, G);
        si.ins_block_group(2 * G, G);
        si.ins_extent(G + K, 4 * K);
        si.ins_extent(2 * G + 10 * K, 256 * M);
        assert_eq!(si.block_groups.len(), 2);
        for bg in si.block_groups.values() {
            assert_eq!(bg.extents.len(), 1);
        }
    }
    #[test]
    fn del_extents() {
        let mut si = SpaceInfo::new();
        si.ins_block_group(G, G);
        si.ins_block_group(2 * G, G);
        si.ins_extent(G + K, 4 * K);
        si.ins_extent(G + 10 * K, 256 * M);
        si.ins_extent(2 * G + 10 * K, 256 * M);
        assert_eq!(si.block_groups.len(), 2);
        si.del_extent(G + 10 * K);
        for bg in si.block_groups.values() {
            assert_eq!(bg.extents.len(), 1);
        }
    }
    // various scenarios with missing block group
    #[test]
    fn test_no_bg() {}

    // various scenarios with invalid overlapping block_groups
    #[test]
    fn test_bg_overlap() {}

    // various scenarios with invalid overlapping extents
    #[test]
    fn test_extent_overlap() {}
}
