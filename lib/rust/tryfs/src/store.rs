//! Where blocks live while the filesystem works on them.
//!
//! A [`Store`] holds copies of blocks in slots: the file server's slots
//! are its block windows, the host's are a whole disk image in memory.
//! The filesystem asks for a block by number ([`Store::load`]) and then
//! reads and writes its words through the slot it gets back. A slot
//! stays the block's through the next three loads at least: the tree
//! never needs more than four blocks at once.
//!
//! A slot that changed is dirty until [`Store::flush`] writes it. The
//! store may write a dirty block early to make room, but only a fresh
//! one, which nothing on the disk points to yet (every changed node is,
//! and so is a new data block); [`Store::seal`] is called on a node
//! before it is written. The superblock, block 0, goes last of all.

use crate::Result;

/// A block's place in the store.
pub type Slot = usize;

pub trait Store {
    /// Make block `b` available, reading it if need be, and return its
    /// slot.
    fn load(&mut self, b: i64) -> Result<Slot>;

    /// Make block `b` a block of zeros, dirty, without reading it: a
    /// block just allocated.
    fn zero(&mut self, b: i64) -> Result<Slot>;

    /// Word `i` (0 to BLOCK_WORDS - 1) of the block in slot `s`.
    fn word(&self, s: Slot, i: usize) -> i64;

    /// Change word `i` of the block in slot `s`, which makes it dirty.
    fn set_word(&mut self, s: Slot, i: usize, w: i64);

    /// Move `n` words within slot `s` from word `from` to word `to`, as
    /// memmove does.
    fn move_words(&mut self, s: Slot, from: usize, to: usize, n: usize) {
        if to < from {
            for k in 0..n {
                let w = self.word(s, from + k);
                self.set_word(s, to + k, w);
            }
        } else {
            for k in (0..n).rev() {
                let w = self.word(s, from + k);
                self.set_word(s, to + k, w);
            }
        }
    }

    /// Copy `n` words from slot `a`'s word `from` to slot `b`'s word `to`.
    fn copy_words(&mut self, a: Slot, from: usize, b: Slot, to: usize, n: usize) {
        for k in 0..n {
            let w = self.word(a, from + k);
            self.set_word(b, to + k, w);
        }
    }

    /// The block in slot `s` becomes block `to`, dirty: a copy about to
    /// change. The block it was keeps what the disk has. The new slot.
    fn copy_to(&mut self, s: Slot, to: i64) -> Result<Slot>;

    /// Forget block `b`, dirty or not: it is free again.
    fn forget(&mut self, b: i64);

    /// Whether the node in slot `s` has had its sum checked since it was
    /// read, and say that it has.
    fn checked(&self, s: Slot) -> bool;
    fn set_checked(&mut self, s: Slot);

    /// Say that slot `s` holds a node, so that it is sealed (its sequence
    /// number and sum filled in, [`crate::node::seal`]) before it is
    /// written.
    fn set_node(&mut self, s: Slot);

    /// The commit the nodes written from now on belong to.
    fn set_seq(&mut self, seq: i64);

    /// Write every dirty block, block 0 last, sealing each node first.
    fn flush(&mut self) -> Result<()>;

    /// Drop every change since the last flush: dirty blocks are
    /// forgotten, and read again from the disk if needed.
    fn discard(&mut self);
}
