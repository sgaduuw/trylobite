//! A set of block numbers, one bit each, up to FS_MAX_BLOCKS. It
//! remembers the range of its words it has set bits in, so emptying it
//! after each call costs only what the call touched.

use crate::layout::FS_MAX_BLOCKS;

const WORDS: usize = (FS_MAX_BLOCKS as usize).div_ceil(32);

pub struct Bits {
    w: [u32; WORDS],
    lo: usize, // the words that may have bits set: lo to hi - 1
    hi: usize,
}

impl Bits {
    pub const fn new() -> Self {
        Bits { w: [0; WORDS], lo: WORDS, hi: 0 }
    }

    #[inline]
    pub fn has(&self, b: i64) -> bool {
        let b = b as usize;
        self.w[b / 32] & (1 << (b % 32)) != 0
    }

    pub fn set(&mut self, b: i64) {
        let b = b as usize;
        let i = b / 32;
        self.w[i] |= 1 << (b % 32);
        self.lo = self.lo.min(i);
        self.hi = self.hi.max(i + 1);
    }

    pub fn clear(&mut self, b: i64) {
        let b = b as usize;
        self.w[b / 32] &= !(1 << (b % 32));
    }

    pub fn is_empty(&self) -> bool {
        self.lo >= self.hi
    }

    /// Take every bit away.
    pub fn empty(&mut self) {
        for i in self.lo..self.hi {
            self.w[i] = 0;
        }
        self.lo = WORDS;
        self.hi = 0;
    }

    /// Take away from `self` every bit `other` has.
    pub fn remove_all(&mut self, other: &Bits) {
        for i in other.lo..other.hi {
            self.w[i] &= !other.w[i];
        }
    }

    /// The first block from `from` up to `end` - 1 that is not in the
    /// set, if any.
    pub fn first_clear(&self, from: i64, end: i64) -> Option<i64> {
        let mut b = from;
        while b < end {
            let i = b as usize / 32;
            if self.w[i] == u32::MAX && b % 32 == 0 {
                b += 32; // a whole word in use
                continue;
            }
            if !self.has(b) {
                return Some(b);
            }
            b += 1;
        }
        None
    }

    /// The last block from `end` - 1 down to `from` that is not in the
    /// set, if any.
    pub fn last_clear(&self, from: i64, end: i64) -> Option<i64> {
        let mut b = end - 1;
        while b >= from {
            let i = b as usize / 32;
            if self.w[i] == u32::MAX && b % 32 == 31 {
                b -= 32; // a whole word in use
                continue;
            }
            if !self.has(b) {
                return Some(b);
            }
            b -= 1;
        }
        None
    }

    /// How many of blocks 0 to `end` - 1 are in the set.
    pub fn count(&self, end: i64) -> i64 {
        let mut n = 0;
        let mut b = 0;
        while b < end {
            if b % 32 == 0 && b + 32 <= end {
                n += self.w[b as usize / 32].count_ones() as i64;
                b += 32;
            } else {
                n += self.has(b) as i64;
                b += 1;
            }
        }
        n
    }
}
