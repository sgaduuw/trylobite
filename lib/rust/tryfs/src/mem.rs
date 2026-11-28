//! The host's store: a whole disk image in memory, as the disk tool and
//! the tests use it. A disk image file is detrytus' (docs/platform.md):
//! each tryte a little-endian i16, PAGE of them to a block.

use std::collections::{HashMap, HashSet};
use std::vec::Vec;

use crate::layout::*;
use crate::node;
use crate::store::{Slot, Store};
use crate::Result;

const W: usize = BLOCK_WORDS as usize;
const DIGIT: i64 = 19683; // 3^9

pub struct MemStore {
    blocks: Vec<Vec<i64>>,
    /// Blocks changed since the last flush, as they were before.
    undo: HashMap<usize, Vec<i64>>,
    dirty: HashSet<usize>,
    nodes: HashSet<usize>,
    checked: HashSet<usize>,
    seq: i64,
}

/// A balanced digit of base 3^9 and what is left above it.
fn digit(w: i64) -> (i64, i64) {
    let mut d = w.rem_euclid(DIGIT);
    if d > DIGIT / 2 {
        d -= DIGIT;
    }
    (d, (w - d) / DIGIT)
}

/// A word's three trytes, low first.
pub fn split(w: i64) -> [i64; 3] {
    let (t0, rest) = digit(w);
    let (t1, rest) = digit(rest);
    [t0, t1, rest]
}

/// The word of three trytes, low first.
pub fn join(t: [i64; 3]) -> i64 {
    t[0] + DIGIT * (t[1] + DIGIT * t[2])
}

impl MemStore {
    /// A disk of `n` blocks of zeros.
    pub fn new(n: usize) -> MemStore {
        MemStore::from_blocks(std::vec![std::vec![0; W]; n])
    }

    fn from_blocks(blocks: Vec<Vec<i64>>) -> MemStore {
        MemStore {
            blocks,
            undo: HashMap::new(),
            dirty: HashSet::new(),
            nodes: HashSet::new(),
            checked: HashSet::new(),
            seq: 0,
        }
    }

    /// A disk image file's blocks; a last part block is padded with zeros.
    pub fn from_image(data: &[u8]) -> MemStore {
        let trytes: Vec<i64> = data.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]]) as i64).collect();
        let n = trytes.len().div_ceil(3 * W);
        let mut blocks = std::vec![std::vec![0; W]; n];
        for (i, t) in trytes.chunks(3).enumerate() {
            let get = |k: usize| t.get(k).copied().unwrap_or(0);
            blocks[i / W][i % W] = join([get(0), get(1), get(2)]);
        }
        MemStore::from_blocks(blocks)
    }

    /// The disk image file of these blocks.
    pub fn image(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.blocks.len() * W * 6);
        for block in &self.blocks {
            for &w in block {
                for t in split(w) {
                    out.extend_from_slice(&(t as i16).to_le_bytes());
                }
            }
        }
        out
    }

    pub fn len(&self) -> usize {
        self.blocks.len()
    }

    pub fn is_empty(&self) -> bool {
        self.blocks.is_empty()
    }

    /// Block `b`'s trytes, PAGE of them.
    pub fn trytes(&self, b: i64) -> Vec<i64> {
        self.blocks[b as usize].iter().flat_map(|&w| split(w)).collect()
    }

    /// Write trytes into block `b` from its first, the rest left as it was.
    pub fn set_trytes(&mut self, b: i64, trytes: &[i64]) {
        let s = b as usize;
        self.keep(s);
        let block = &mut self.blocks[s];
        for (i, t) in trytes.chunks(3).enumerate() {
            let mut old = split(block[i]);
            old[..t.len()].copy_from_slice(t);
            block[i] = join(old);
        }
        self.dirty.insert(s);
    }

    /// Save how block `s` was before this flush's first change to it.
    fn keep(&mut self, s: usize) {
        if !self.undo.contains_key(&s) {
            self.undo.insert(s, self.blocks[s].clone());
        }
    }
}

impl Store for MemStore {
    fn load(&mut self, b: i64) -> Result<Slot> {
        if b < 0 || b as usize >= self.blocks.len() {
            return Err(E_IO);
        }
        Ok(b as usize)
    }

    fn zero(&mut self, b: i64) -> Result<Slot> {
        let s = self.load(b)?;
        self.keep(s);
        self.blocks[s].iter_mut().for_each(|w| *w = 0);
        self.dirty.insert(s);
        self.nodes.remove(&s);
        self.checked.insert(s);
        Ok(s)
    }

    fn word(&self, s: Slot, i: usize) -> i64 {
        self.blocks[s][i]
    }

    fn set_word(&mut self, s: Slot, i: usize, w: i64) {
        self.keep(s);
        self.blocks[s][i] = w;
        self.dirty.insert(s);
    }

    fn copy_to(&mut self, s: Slot, to: i64) -> Result<Slot> {
        let t = self.load(to)?;
        self.keep(t);
        self.blocks[t] = self.blocks[s].clone();
        self.dirty.insert(t);
        self.checked.insert(t);
        Ok(t)
    }

    fn forget(&mut self, b: i64) {
        self.dirty.remove(&(b as usize));
        self.nodes.remove(&(b as usize));
    }

    fn checked(&self, s: Slot) -> bool {
        self.checked.contains(&s)
    }

    fn set_checked(&mut self, s: Slot) {
        self.checked.insert(s);
    }

    fn set_node(&mut self, s: Slot) {
        self.nodes.insert(s);
    }

    fn set_seq(&mut self, seq: i64) {
        self.seq = seq;
    }

    fn flush(&mut self) -> Result<()> {
        let mut dirty: Vec<usize> = self.dirty.drain().collect();
        dirty.sort();
        for s in dirty {
            if self.nodes.contains(&s) {
                node::seal(self, s, self.seq);
            }
        }
        self.dirty.clear();
        self.undo.clear();
        Ok(())
    }

    fn discard(&mut self) {
        for (s, old) in self.undo.drain() {
            self.blocks[s] = old;
            self.checked.remove(&s);
        }
        self.dirty.clear();
    }
}
