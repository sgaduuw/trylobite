//! One node of the tree, in a slot: its header (NODE_MAGIC, N_LEVEL,
//! N_COUNT, N_USED, N_SEQ, N_SUM), then its items one after another in
//! key order from word N_ITEMS, each [klen, vlen, key..., value...].
//! An item is found by its position: the word it starts at.

use core::cmp::Ordering;

use crate::key::{KEY_WORDS, Key};
use crate::layout::*;
use crate::store::{Slot, Store};
use crate::sum;
use crate::Result;

pub const ITEMS: usize = N_ITEMS as usize;
/// Words the items may take.
pub const ROOM: usize = BLOCK_WORDS as usize - ITEMS;

pub fn level<S: Store>(st: &S, s: Slot) -> i64 {
    st.word(s, N_LEVEL as usize)
}

pub fn count<S: Store>(st: &S, s: Slot) -> usize {
    st.word(s, N_COUNT as usize) as usize
}

pub fn used<S: Store>(st: &S, s: Slot) -> usize {
    st.word(s, N_USED as usize) as usize
}

/// Where the items end.
pub fn end<S: Store>(st: &S, s: Slot) -> usize {
    ITEMS + used(st, s)
}

pub fn klen<S: Store>(st: &S, s: Slot, pos: usize) -> usize {
    st.word(s, pos + IT_KLEN as usize) as usize
}

pub fn vlen<S: Store>(st: &S, s: Slot, pos: usize) -> usize {
    st.word(s, pos + IT_VLEN as usize) as usize
}

/// Words the item at `pos` takes.
pub fn size<S: Store>(st: &S, s: Slot, pos: usize) -> usize {
    IT_KEY as usize + klen(st, s, pos) + vlen(st, s, pos)
}

/// Where the item at `pos`'s value starts.
pub fn value_at<S: Store>(st: &S, s: Slot, pos: usize) -> usize {
    pos + IT_KEY as usize + klen(st, s, pos)
}

/// Word `i` of the value of the item at `pos`.
pub fn value<S: Store>(st: &S, s: Slot, pos: usize, i: usize) -> i64 {
    st.word(s, value_at(st, s, pos) + i)
}

/// The key of the item at `pos`.
pub fn key<S: Store>(st: &S, s: Slot, pos: usize) -> Key {
    let mut k = Key::empty();
    let n = klen(st, s, pos).min(KEY_WORDS);
    for i in 0..n {
        k.w[i] = st.word(s, pos + IT_KEY as usize + i);
    }
    k.len = n;
    k
}

/// Compare the key of the item at `pos` with `k`.
pub fn cmp_key<S: Store>(st: &S, s: Slot, pos: usize, k: &[i64]) -> Ordering {
    let n = klen(st, s, pos);
    let at = pos + IT_KEY as usize;
    for i in 0..n.min(k.len()) {
        let w = st.word(s, at + i);
        if w != k[i] {
            return if w < k[i] { Ordering::Less } else { Ordering::Greater };
        }
    }
    n.cmp(&k.len())
}

/// In a leaf: the position of the first item whose key is `k` or more
/// (more than `k` when `strict`), or where the items end, and whether
/// that item's key is `k`.
pub fn find<S: Store>(st: &S, s: Slot, k: &[i64], strict: bool) -> (usize, bool) {
    let end = end(st, s);
    let mut pos = ITEMS;
    while pos < end {
        match cmp_key(st, s, pos, k) {
            Ordering::Less => {}
            Ordering::Equal if strict => {}
            o => return (pos, o == Ordering::Equal),
        }
        pos += size(st, s, pos);
    }
    (end, false)
}

/// In an inner node: the position of the item whose child holds `k`
/// (the last whose key is `k` or less, or the first), and of the item
/// after it, if there is one.
pub fn child_for<S: Store>(st: &S, s: Slot, k: &[i64]) -> (usize, Option<usize>) {
    let end = end(st, s);
    let mut pos = ITEMS;
    loop {
        let next = pos + size(st, s, pos);
        if next >= end {
            return (pos, None);
        }
        if cmp_key(st, s, next, k) == Ordering::Greater {
            return (pos, Some(next));
        }
        pos = next;
    }
}

/// Room for an item of key `k` and `v` words of value?
pub fn fits<S: Store>(st: &S, s: Slot, k: &Key, vlen: usize) -> bool {
    used(st, s) + IT_KEY as usize + k.len + vlen <= ROOM
}

/// Put an item at `pos`, moving those after it along; the caller has
/// made sure it fits.
pub fn insert<S: Store>(st: &mut S, s: Slot, pos: usize, k: &Key, v: &[i64]) {
    let size = IT_KEY as usize + k.len + v.len();
    let end = end(st, s);
    st.move_words(s, pos, pos + size, end - pos);
    st.set_word(s, pos + IT_KLEN as usize, k.len as i64);
    st.set_word(s, pos + IT_VLEN as usize, v.len() as i64);
    for i in 0..k.len {
        st.set_word(s, pos + IT_KEY as usize + i, k.w[i]);
    }
    let at = pos + IT_KEY as usize + k.len;
    for (i, &w) in v.iter().enumerate() {
        st.set_word(s, at + i, w);
    }
    st.set_word(s, N_COUNT as usize, (count(st, s) + 1) as i64);
    st.set_word(s, N_USED as usize, (used(st, s) + size) as i64);
}

/// Take away the item at `pos`, moving those after it back.
pub fn remove<S: Store>(st: &mut S, s: Slot, pos: usize) {
    let size = size(st, s, pos);
    let end = end(st, s);
    st.move_words(s, pos + size, pos, end - pos - size);
    for i in end - size..end {
        st.set_word(s, i, 0); // a node's unused words are zero
    }
    st.set_word(s, N_COUNT as usize, (count(st, s) - 1) as i64);
    st.set_word(s, N_USED as usize, (used(st, s) - size) as i64);
}

/// Make the zeroed block in slot `s` an empty node at `level`.
pub fn init<S: Store>(st: &mut S, s: Slot, level: i64) {
    st.set_word(s, 0, NODE_MAGIC);
    st.set_word(s, N_LEVEL as usize, level);
    st.set_node(s);
}

/// The sum of the node in slot `s`: its header and items, N_SUM counted
/// as 0.
pub fn sum_of<S: Store>(st: &S, s: Slot) -> i64 {
    let end = end(st, s).min(BLOCK_WORDS as usize);
    let mut sum = 0;
    for i in 0..end {
        let w = if i == N_SUM as usize { 0 } else { st.word(s, i) };
        sum = sum::step(sum, w);
    }
    sum
}

/// Fill in a node's sequence number and sum, just before it is written.
pub fn seal<S: Store>(st: &mut S, s: Slot, seq: i64) {
    st.set_word(s, N_SEQ as usize, seq);
    let sum = sum_of(st, s);
    st.set_word(s, N_SUM as usize, sum);
}

/// Check what a node read from the disk says about itself: E_IO if its
/// magic word, sizes or sum are wrong.
pub fn verify<S: Store>(st: &S, s: Slot) -> Result<()> {
    let bad = st.word(s, 0) != NODE_MAGIC
        || !(0..8).contains(&level(st, s))
        || used(st, s) > ROOM
        || count(st, s) > used(st, s)
        || st.word(s, N_SUM as usize) != sum_of(st, s);
    if bad {
        return Err(E_IO);
    }
    // The items must add up to N_USED.
    let end = end(st, s);
    let mut pos = ITEMS;
    for _ in 0..count(st, s) {
        if pos + IT_KEY as usize > end
            || klen(st, s, pos) > KEY_WORDS
            || vlen(st, s, pos) > ROOM
        {
            return Err(E_IO);
        }
        pos += size(st, s, pos);
    }
    if pos != end {
        return Err(E_IO);
    }
    Ok(())
}
