//! The B-tree: finding, putting and deleting items by key.
//!
//! Every change copies the nodes it touches, from the leaf up to the
//! root ([`Fs::cow`]), unless this call has copied them already. A leaf
//! that would overflow splits in two by words, and the split goes up
//! the path; a root that splits gets a new root above it. A node left
//! empty is taken out of its parent, and a root with one child gives way
//! to it. There are no sibling links, which copy-on-write would have to
//! keep up: the next leaf is found from the parent's next key.

use core::cmp::Ordering;

use crate::fs::Fs;
use crate::key::{self, Key};
use crate::layout::*;
use crate::node;
use crate::store::Store;
use crate::Result;

/// Levels a tree may have: far more than FS_MAX_BLOCKS blocks need.
const DEPTH: usize = 8;

/// The words of the longest value, an inode's.
pub const VALUE_MAX: usize = INODE_WORDS as usize;

/// The way from the root down to a leaf: each node's block, and the
/// position in it of the item leading down.
struct Path {
    depth: usize,
    block: [i64; DEPTH],
    pos: [usize; DEPTH],
}

/// An item found: its key and its value.
pub struct Item {
    pub key: Key,
    pub len: usize,
    pub value: [i64; VALUE_MAX],
}

impl Item {
    pub const fn new() -> Item {
        Item { key: Key::empty(), len: 0, value: [0; VALUE_MAX] }
    }

    pub fn value(&self) -> &[i64] {
        &self.value[..self.len]
    }
}

impl<S: Store> Fs<S> {
    /// Go down from the root to the leaf that holds `k`, or would.
    fn descend(&mut self, k: &[i64], path: &mut Path) -> Result<()> {
        let mut b = self.root;
        path.depth = 0;
        loop {
            if path.depth == DEPTH {
                return Err(E_IO);
            }
            let s = self.node(b)?;
            path.block[path.depth] = b;
            if node::level(&self.store, s) == 0 {
                path.depth += 1;
                return Ok(());
            }
            if node::count(&self.store, s) == 0 {
                return Err(E_IO); // an inner node always has a child
            }
            let (pos, _) = node::child_for(&self.store, s, k);
            path.pos[path.depth] = pos;
            path.depth += 1;
            b = node::value(&self.store, s, pos, 0);
        }
    }

    /// The first item whose key is `k` or more (more than `k` when
    /// `strict`), into `out`: false if there is none.
    pub fn seek(&mut self, k: &Key, strict: bool, out: &mut Item) -> Result<bool> {
        let mut k = *k;
        let mut strict = strict;
        loop {
            let mut b = self.root;
            let mut upper: Option<Key> = None; // where the next leaf starts
            let mut levels = 0;
            let s = loop {
                levels += 1;
                if levels > DEPTH {
                    return Err(E_IO);
                }
                let s = self.node(b)?;
                if node::level(&self.store, s) == 0 {
                    break s;
                }
                if node::count(&self.store, s) == 0 {
                    return Err(E_IO);
                }
                let (pos, next) = node::child_for(&self.store, s, k.words());
                if let Some(next) = next {
                    upper = Some(node::key(&self.store, s, next));
                }
                b = node::value(&self.store, s, pos, 0);
            };
            let (pos, _) = node::find(&self.store, s, k.words(), strict);
            if pos < node::end(&self.store, s) {
                out.key = node::key(&self.store, s, pos);
                out.len = node::vlen(&self.store, s, pos).min(VALUE_MAX);
                for i in 0..out.len {
                    out.value[i] = node::value(&self.store, s, pos, i);
                }
                return Ok(true);
            }
            match upper {
                Some(u) => {
                    k = u;
                    strict = false;
                }
                None => return Ok(false),
            }
        }
    }

    /// The item whose key is `k`, into `out`: false if there is none.
    pub fn get(&mut self, k: &Key, out: &mut Item) -> Result<bool> {
        Ok(self.seek(k, false, out)? && key::cmp(out.key.words(), k.words()) == Ordering::Equal)
    }

    /// Put an item of key `k` and value `v`, in place of one of that key
    /// if there is one.
    pub fn put(&mut self, k: &Key, v: &[i64]) -> Result<()> {
        let mut path = Path { depth: 0, block: [0; DEPTH], pos: [0; DEPTH] };
        self.descend(k.words(), &mut path)?;
        let mut level = path.depth - 1;
        let mut b = self.cow(path.block[level])?;
        let s = self.node(b)?;
        let (pos, exact) = node::find(&self.store, s, k.words(), false);
        if exact {
            node::remove(&mut self.store, s, pos);
        }
        let mut split = self.insert_at(b, pos, k, v)?;
        while level > 0 {
            level -= 1;
            let child = b;
            b = self.cow(path.block[level])?;
            let s = self.node(b)?;
            let pos = path.pos[level];
            let at = node::value_at(&self.store, s, pos);
            self.store.set_word(s, at, child);
            split = match split {
                None => None,
                Some((sep, right)) => {
                    let next = pos + node::size(&self.store, s, pos);
                    self.insert_at(b, next, &sep, &[right])?
                }
            };
        }
        self.root = b;
        if let Some((sep, right)) = split {
            // The root split: a new root above the two halves.
            let s = self.node(b)?;
            let first = node::key(&self.store, s, node::ITEMS);
            let up = node::level(&self.store, s) + 1;
            let nb = self.alloc(b)?;
            let s = self.store.zero(nb)?;
            node::init(&mut self.store, s, up);
            node::insert(&mut self.store, s, node::ITEMS, &first, &[b]);
            let end = node::end(&self.store, s);
            node::insert(&mut self.store, s, end, &sep, &[right]);
            self.root = nb;
        }
        Ok(())
    }

    /// Put an item at position `pos` of fresh node `b`, splitting the node
    /// if it does not fit: the new right half's first key and block if it
    /// split.
    fn insert_at(&mut self, b: i64, pos: usize, k: &Key, v: &[i64]) -> Result<Option<(Key, i64)>> {
        let s = self.node(b)?;
        if node::fits(&self.store, s, k, v.len()) {
            node::insert(&mut self.store, s, pos, k, v);
            return Ok(None);
        }
        // Split by words, so that the halves end up about even with the
        // new item counted.
        let level = node::level(&self.store, s);
        let end = node::end(&self.store, s);
        let total = node::used(&self.store, s) + key::KEY_WORDS + v.len();
        let mut cut = node::ITEMS;
        let mut kept = 0;
        while cut < end && (kept == 0 || cut - node::ITEMS < total / 2) {
            cut += node::size(&self.store, s, cut);
            kept += 1;
        }
        if cut >= end {
            return Err(E_IO); // one item takes a whole node: cannot happen
        }
        let rb = self.alloc(b)?;
        let r = self.store.zero(rb)?;
        node::init(&mut self.store, r, level);
        let s = self.node(b)?;
        let moved = end - cut;
        self.store.copy_words(s, cut, r, node::ITEMS, moved);
        let n = node::count(&self.store, s);
        self.store.set_word(r, N_COUNT as usize, (n - kept) as i64);
        self.store.set_word(r, N_USED as usize, moved as i64);
        for i in cut..end {
            self.store.set_word(s, i, 0);
        }
        self.store.set_word(s, N_COUNT as usize, kept as i64);
        self.store.set_word(s, N_USED as usize, (cut - node::ITEMS) as i64);
        // The new item goes to whichever half its position is in.
        if pos <= cut && !(pos == cut && kept == 0) {
            node::insert(&mut self.store, s, pos, k, v);
        } else {
            let r = self.node(rb)?;
            node::insert(&mut self.store, r, pos - cut + node::ITEMS, k, v);
        }
        let r = self.node(rb)?;
        let sep = node::key(&self.store, r, node::ITEMS);
        Ok(Some((sep, rb)))
    }

    /// Take away the item of key `k`: false if there was none.
    pub fn delete(&mut self, k: &Key) -> Result<bool> {
        let mut path = Path { depth: 0, block: [0; DEPTH], pos: [0; DEPTH] };
        self.descend(k.words(), &mut path)?;
        let mut level = path.depth - 1;
        {
            let s = self.node(path.block[level])?;
            if !node::find(&self.store, s, k.words(), false).1 {
                return Ok(false);
            }
        }
        let mut b = self.cow(path.block[level])?;
        let s = self.node(b)?;
        let (pos, _) = node::find(&self.store, s, k.words(), false);
        node::remove(&mut self.store, s, pos);
        let mut empty = node::count(&self.store, s) == 0;
        while level > 0 {
            level -= 1;
            let child = b;
            b = self.cow(path.block[level])?;
            let s = self.node(b)?;
            let pos = path.pos[level];
            if empty {
                node::remove(&mut self.store, s, pos);
                self.release(child);
                empty = node::count(&self.store, s) == 0;
            } else {
                let at = node::value_at(&self.store, s, pos);
                self.store.set_word(s, at, child);
            }
        }
        self.root = b;
        loop {
            let s = self.node(self.root)?;
            let level = node::level(&self.store, s);
            let n = node::count(&self.store, s);
            if level == 0 || n > 1 {
                break;
            }
            let old = self.root;
            if n == 1 {
                // A root with one child: the child is the root.
                self.root = node::value(&self.store, s, node::ITEMS, 0);
            } else {
                // Every leaf went: an empty leaf is the root.
                let nb = self.alloc(old)?;
                let s = self.store.zero(nb)?;
                node::init(&mut self.store, s, 0);
                self.root = nb;
            }
            self.release(old);
        }
        Ok(true)
    }
}
