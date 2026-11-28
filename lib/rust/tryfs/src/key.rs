//! Keys: words compared one by one, a shorter key first when it is the
//! start of a longer one. Every key starts with an inode number and a
//! kind (K_INODE, K_DIRENT, K_EXTENT), so an inode's records sit
//! together, its own first.
//!
//! A balanced-ternary word compares as its trits do, most significant
//! first, negatives included, so a key is in effect one long trit
//! string. A directory entry's key carries its name, three code points
//! to a word with the first the most significant ([`pack`]): code
//! points are balanced digits of base 3^9, so names sort as strings and
//! a directory reads in name order.

use core::cmp::Ordering;

use crate::layout::*;

pub const KEY_WORDS: usize = KEY_MAX as usize;
pub const NAME_LEN: usize = NAME_MAX as usize;
const DIGIT: i64 = 19683; // 3^9: a tryte's range

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Key {
    pub len: usize,
    pub w: [i64; KEY_WORDS],
}

impl Key {
    pub const fn empty() -> Key {
        Key { len: 0, w: [0; KEY_WORDS] }
    }

    /// The key of inode `ino`'s own record.
    pub fn inode(ino: i64) -> Key {
        let mut k = Key::empty();
        k.w[0] = ino;
        k.w[1] = K_INODE;
        k.len = 2;
        k
    }

    /// The key of the extent of inode `ino` that ends at file block
    /// `end` (it holds blocks below `end`).
    pub fn extent(ino: i64, end: i64) -> Key {
        let mut k = Key::empty();
        k.w[0] = ino;
        k.w[1] = K_EXTENT;
        k.w[2] = end;
        k.len = 3;
        k
    }

    /// The key of directory `dir`'s entry `name`, code points; the first
    /// key of its entries with no name.
    pub fn dirent(dir: i64, name: &[i32]) -> Key {
        let mut k = Key::empty();
        k.w[0] = dir;
        k.w[1] = K_DIRENT;
        k.len = 2 + pack(name, &mut k.w[2..]);
        k
    }

    pub fn ino(&self) -> i64 {
        self.w[0]
    }

    pub fn kind(&self) -> i64 {
        self.w[1]
    }

    pub fn words(&self) -> &[i64] {
        &self.w[..self.len]
    }

    /// The name of a directory entry's key, as code points, into `out`:
    /// how many.
    pub fn name(&self, out: &mut [i32; NAME_LEN]) -> usize {
        unpack(&self.w[2..self.len], out, trytes)
    }

    /// The same, splitting each word with `split` (see [`trytes`]).
    pub fn name_with(&self, out: &mut [i32; NAME_LEN], split: impl Fn(i64) -> [i64; 3]) -> usize {
        unpack(&self.w[2..self.len], out, split)
    }
}

/// Compare two keys given as words.
pub fn cmp(a: &[i64], b: &[i64]) -> Ordering {
    let n = a.len().min(b.len());
    for i in 0..n {
        if a[i] != b[i] {
            return if a[i] < b[i] { Ordering::Less } else { Ordering::Greater };
        }
    }
    a.len().cmp(&b.len())
}

/// Pack code points into words, three to a word, the first the most
/// significant, the last word padded with 0: how many words.
pub fn pack(name: &[i32], out: &mut [i64]) -> usize {
    let mut n = 0;
    let mut i = 0;
    while i < name.len() {
        let c = |k: usize| name.get(k).copied().unwrap_or(0) as i64;
        out[n] = (c(i) * DIGIT + c(i + 1)) * DIGIT + c(i + 2);
        n += 1;
        i += 3;
    }
    n
}

/// A word's three balanced digits of base 3^9, low first: its trytes.
/// This takes 64-bit division, a long loop on detrytus, where the file
/// server reads the trytes of a word directly instead (Key::name_with).
pub fn trytes(w: i64) -> [i64; 3] {
    let (c2, rest) = digit(w);
    let (c1, rest) = digit(rest);
    let (c0, _) = digit(rest);
    [c2, c1, c0]
}

/// The balanced digit of base 3^9 at the bottom of `w`, and what is
/// left above it.
fn digit(w: i64) -> (i64, i64) {
    let mut d = w % DIGIT; // Rust's % keeps the sign of w
    if d > DIGIT / 2 {
        d -= DIGIT;
    } else if d < -(DIGIT / 2) {
        d += DIGIT;
    }
    (d, (w - d) / DIGIT)
}

/// Unpack words of a name into code points, stopping at the first 0:
/// how many.
pub fn unpack(words: &[i64], out: &mut [i32; NAME_LEN], split: impl Fn(i64) -> [i64; 3]) -> usize {
    let mut n = 0;
    for &w in words {
        let [c2, c1, c0] = split(w);
        for c in [c0, c1, c2] {
            if c == 0 || n == NAME_LEN {
                return n;
            }
            out[n] = c as i32;
            n += 1;
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(s: &str) -> std::vec::Vec<i32> {
        s.chars().map(|c| c as i32).collect()
    }

    #[test]
    fn names_sort_as_strings() {
        let mut names = ["b", "a", "ab", "abc", "abcd", "Z", "_x", "a.b", "zz", "\u{2603}"];
        let mut keys: std::vec::Vec<Key> = names.iter().map(|n| Key::dirent(5, &name(n))).collect();
        keys.sort_by(|a, b| cmp(a.words(), b.words()));
        names.sort();
        for (k, n) in keys.iter().zip(names) {
            let mut out = [0; NAME_LEN];
            let len = k.name(&mut out);
            assert_eq!(&out[..len], &name(n)[..]);
        }
    }

    #[test]
    fn an_inode_comes_before_its_entries_and_extents() {
        let i = Key::inode(7);
        let d = Key::dirent(7, &name("a"));
        let e = Key::extent(7, 1);
        let next = Key::inode(8);
        assert_eq!(cmp(i.words(), d.words()), Ordering::Less);
        assert_eq!(cmp(d.words(), e.words()), Ordering::Less);
        assert_eq!(cmp(e.words(), next.words()), Ordering::Less);
        assert_eq!(cmp(Key::dirent(7, &[]).words(), d.words()), Ordering::Less);
    }

    #[test]
    fn the_longest_name_fits_a_key() {
        let long = std::vec![0x2603; NAME_LEN];
        let k = Key::dirent(1, &long);
        assert_eq!(k.len, KEY_WORDS);
        let mut out = [0; NAME_LEN];
        assert_eq!(k.name(&mut out), NAME_LEN);
        assert_eq!(&out[..], &long[..]);
    }
}
