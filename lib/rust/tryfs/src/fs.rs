//! The filesystem as a whole: the superblock, which blocks are in use,
//! and transactions. The tree is in tree.rs, inodes, directories and
//! files in ops.rs.
//!
//! Which blocks are in use is not on the disk: [`Fs::mount`] works it
//! out by walking the tree, which owns every block but the superblock
//! and the boot record's. While a call runs, blocks it allocates are
//! *fresh* (nothing on the disk points to them, so they may change in
//! place and be written at any time) and blocks it stops using are
//! *freed*, but stay in use until the commit, since the tree on the disk
//! still points to them.

use crate::bits::Bits;
use crate::layout::*;
use crate::node;
use crate::store::Store;
use crate::sum;
use crate::Result;

/// A time: seconds since 1970-01-01 UTC and nanoseconds.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Time {
    pub secs: i64,
    pub nanos: i64,
}

/// An inode's record, as INODE_WORDS words.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Inode {
    pub ino: i64,
    pub typ: i64,
    pub mode: i64,
    pub uid: i64,
    pub gid: i64,
    pub links: i64,
    pub size: i64,
    pub atime: Time,
    pub mtime: Time,
    pub ctime: Time,
    pub btime: Time,
    pub parent: i64,
}

impl Inode {
    pub fn is_dir(&self) -> bool {
        self.typ == T_DIR
    }

    pub fn to_words(&self) -> [i64; INODE_WORDS as usize] {
        let mut w = [0; INODE_WORDS as usize];
        w[IN_TYPE as usize] = self.typ;
        w[IN_MODE as usize] = self.mode;
        w[IN_UID as usize] = self.uid;
        w[IN_GID as usize] = self.gid;
        w[IN_LINKS as usize] = self.links;
        w[IN_SIZE as usize] = self.size;
        for (at, t) in [
            (IN_ATIME, self.atime),
            (IN_MTIME, self.mtime),
            (IN_CTIME, self.ctime),
            (IN_BTIME, self.btime),
        ] {
            w[at as usize] = t.secs;
            w[at as usize + 1] = t.nanos;
        }
        w[IN_PARENT as usize] = self.parent;
        w
    }

    pub fn from_words(ino: i64, w: &[i64]) -> Inode {
        let t = |at: i64| Time { secs: w[at as usize], nanos: w[at as usize + 1] };
        Inode {
            ino,
            typ: w[IN_TYPE as usize],
            mode: w[IN_MODE as usize],
            uid: w[IN_UID as usize],
            gid: w[IN_GID as usize],
            links: w[IN_LINKS as usize],
            size: w[IN_SIZE as usize],
            atime: t(IN_ATIME),
            mtime: t(IN_MTIME),
            ctime: t(IN_CTIME),
            btime: t(IN_BTIME),
            parent: w[IN_PARENT as usize],
        }
    }
}

/// The superblock's fields that change, as one call left them.
#[derive(Clone, Copy)]
struct Head {
    root: i64,
    next_ino: i64,
    inodes: i64,
}

pub struct Fs<S: Store> {
    pub store: S,
    /// Whether the disk holds a filesystem this crate can read, as far as
    /// [`Fs::mount`] found.
    pub mounted: bool,
    /// Blocks in the filesystem.
    pub blocks: i64,
    pub root: i64,
    pub seq: i64,
    pub next_ino: i64,
    pub inodes: i64,
    /// The time this call happens at: what it stamps on what it changes.
    pub now: Time,
    committed: Head,
    pub(crate) used: Bits,
    pub(crate) fresh: Bits,
    pub(crate) freed: Bits,
    /// Where the next allocation looks first.
    rotor: i64,
}

/// The superblock's words that the sum covers, read from slot `s`.
fn head_sum<S: Store>(st: &S, s: usize) -> i64 {
    let mut sum = 0;
    for i in 0..SB_WORDS as usize {
        let w = if i == SB_SUM as usize { 0 } else { st.word(s, i) };
        sum = sum::step(sum, w);
    }
    sum
}

/// A superblock word's index from its offset from the block's centre.
const fn word_of(offset: i64) -> usize {
    ((offset - BLOCK_W0) / 3) as usize
}

impl<S: Store> Fs<S> {
    pub const fn new(store: S) -> Self {
        let none = Head { root: 0, next_ino: 0, inodes: 0 };
        Fs {
            store,
            mounted: false,
            blocks: 0,
            root: 0,
            seq: 0,
            next_ino: 0,
            inodes: 0,
            now: Time { secs: 0, nanos: 0 },
            committed: none,
            used: Bits::new(),
            fresh: Bits::new(),
            freed: Bits::new(),
            rotor: 1,
        }
    }

    /// Make a new, empty filesystem of `blocks` blocks on the store's
    /// disk: a superblock, a root directory and a leaf holding it. The
    /// boot record is left as it was.
    pub fn format(&mut self, blocks: i64) -> Result<()> {
        if !(2..=FS_MAX_BLOCKS).contains(&blocks) {
            return Err(E_INVAL);
        }
        self.used.empty();
        self.fresh.empty();
        self.freed.empty();
        self.blocks = blocks;
        self.seq = 0;
        self.used.set(0);
        let s = self.store.load(0)?;
        // A new superblock: whatever was there before but the boot
        // record goes.
        for i in 0..BLOCK_WORDS as usize {
            let boot = (word_of(FS_HEAD_BOOT)..=word_of(BOOT_ENTRY) + 1).contains(&i);
            if !boot && self.store.word(s, i) != 0 {
                self.store.set_word(s, i, 0);
            }
        }
        self.mark_boot()?;
        let leaf = self.alloc(1)?;
        let s = self.store.zero(leaf)?;
        node::init(&mut self.store, s, 0);
        self.root = leaf;
        self.next_ino = ROOT_INO;
        self.inodes = 0;
        self.committed = Head { root: 0, next_ino: ROOT_INO, inodes: 0 };
        self.mounted = true;
        let ino = self.new_inode(T_DIR, MODE_DIR, ROOT_INO)?;
        debug_assert_eq!(ino.ino, ROOT_INO);
        self.commit()
    }

    /// Read the superblock and walk the tree, to learn which blocks are
    /// in use: E_NOFS if the disk holds no filesystem of this version,
    /// E_IO if what it holds is damaged.
    pub fn mount(&mut self) -> Result<()> {
        self.mounted = false;
        self.used.empty();
        self.fresh.empty();
        self.freed.empty();
        let s = self.store.load(0).map_err(|_| E_NOFS)?;
        let st = &self.store;
        if st.word(s, word_of(FS_HEAD_MAGIC)) != FS_MAGIC
            || st.word(s, word_of(FS_HEAD_VERSION)) != FS_VERSION
        {
            return Err(E_NOFS);
        }
        if st.word(s, SB_SUM as usize) != head_sum(st, s) {
            return Err(E_IO);
        }
        self.blocks = st.word(s, word_of(FS_HEAD_BLOCKS));
        self.root = st.word(s, SB_ROOT as usize);
        self.seq = st.word(s, SB_SEQ as usize);
        self.next_ino = st.word(s, SB_NEXT_INO as usize);
        self.inodes = st.word(s, SB_INODES as usize);
        if !(2..=FS_MAX_BLOCKS).contains(&self.blocks) || !self.in_range(self.root) {
            return Err(E_IO);
        }
        self.used.set(0);
        self.mark_boot()?;
        self.walk(self.root, -1)?;
        self.committed = Head { root: self.root, next_ino: self.next_ino, inodes: self.inodes };
        self.mounted = true;
        Ok(())
    }

    /// Mark the boot record's blocks in use.
    fn mark_boot(&mut self) -> Result<()> {
        let s = self.store.load(0)?;
        let st = &self.store;
        if st.word(s, word_of(FS_HEAD_BOOT)) != BOOT_MAGIC {
            return Ok(());
        }
        let first = st.word(s, word_of(BOOT_FIRST));
        let n = st.word(s, word_of(BOOT_COUNT));
        if first < 1 || n < 1 || first + n > self.blocks {
            return Err(E_IO);
        }
        for b in first..first + n {
            self.used.set(b);
        }
        Ok(())
    }

    fn in_range(&self, b: i64) -> bool {
        0 < b && b < self.blocks
    }

    /// Mark node `b` and everything under it in use: E_IO for a node that
    /// is damaged, at the wrong level (`level`, or any at the root: -1),
    /// or a block used twice.
    fn walk(&mut self, b: i64, level: i64) -> Result<()> {
        if !self.in_range(b) || self.used.has(b) {
            return Err(E_IO);
        }
        self.used.set(b);
        let s = self.node(b)?;
        let here = node::level(&self.store, s);
        if level >= 0 && here != level {
            return Err(E_IO);
        }
        let n = node::count(&self.store, s);
        let mut pos = node::ITEMS;
        for _ in 0..n {
            let s = self.node(b)?; // the walk below may have moved it
            let next = pos + node::size(&self.store, s, pos);
            if here > 0 {
                let child = node::value(&self.store, s, pos, 0);
                self.walk(child, here - 1)?;
            } else if node::klen(&self.store, s, pos) == 3
                && node::key(&self.store, s, pos).kind() == K_EXTENT
            {
                let start = node::value(&self.store, s, pos, EX_START as usize);
                let len = node::value(&self.store, s, pos, EX_LEN as usize);
                if len < 1 || !self.in_range(start) || !self.in_range(start + len - 1) {
                    return Err(E_IO);
                }
                for d in start..start + len {
                    if self.used.has(d) {
                        return Err(E_IO);
                    }
                    self.used.set(d);
                }
            }
            pos = next;
        }
        Ok(())
    }

    /// Node `b`'s slot, its sum checked if it was just read.
    pub fn node(&mut self, b: i64) -> Result<usize> {
        let s = self.store.load(b)?;
        if !self.store.checked(s) {
            node::verify(&self.store, s)?;
            self.store.set_checked(s);
            self.store.set_node(s);
        }
        Ok(s)
    }

    /// A free block, fresh: one after `near` if there is one, else the
    /// first free one. E_NOSPC if there are none.
    pub fn alloc(&mut self, near: i64) -> Result<i64> {
        let from = if self.in_range(near) { near } else { self.rotor };
        let b = match self.used.first_clear(from, self.blocks) {
            Some(b) => b,
            None => self.used.first_clear(1, from).ok_or(E_NOSPC)?,
        };
        self.used.set(b);
        self.fresh.set(b);
        self.rotor = b + 1;
        Ok(b)
    }

    /// Block `b` if it is free, fresh: for growing an extent in place.
    pub fn alloc_at(&mut self, b: i64) -> bool {
        if !self.in_range(b) || self.used.has(b) {
            return false;
        }
        self.used.set(b);
        self.fresh.set(b);
        true
    }

    /// Stop using block `b`: at once if it is fresh, else at the commit.
    pub fn release(&mut self, b: i64) {
        if self.fresh.has(b) {
            self.fresh.clear(b);
            self.used.clear(b);
            self.store.forget(b);
        } else {
            self.freed.set(b);
        }
    }

    pub fn is_fresh(&self, b: i64) -> bool {
        self.fresh.has(b)
    }

    /// Node `b`, ready to change: itself if it is fresh, else a copy in a
    /// fresh block, `b` to be freed at the commit. The block it is in
    /// now.
    pub fn cow(&mut self, b: i64) -> Result<i64> {
        if self.fresh.has(b) {
            return Ok(b);
        }
        let s = self.node(b)?;
        let nb = self.alloc(b)?;
        let s = self.store.copy_to(s, nb)?;
        self.store.set_node(s);
        self.freed.set(b);
        Ok(nb)
    }

    /// Whether this call has changed anything.
    pub fn changed(&self) -> bool {
        !self.fresh.is_empty()
            || !self.freed.is_empty()
            || self.root != self.committed.root
            || self.next_ino != self.committed.next_ino
            || self.inodes != self.committed.inodes
    }

    /// Put what this call did on the disk: every changed block, then the
    /// superblock naming the new root. Then the blocks the old tree used
    /// are free. E_IO if the disk refused, after which the filesystem
    /// must be mounted again.
    pub fn commit(&mut self) -> Result<()> {
        if !self.changed() {
            return Ok(());
        }
        let seq = self.seq + 1;
        self.store.set_seq(seq);
        let s = self.store.load(0)?;
        let st = &mut self.store;
        st.set_word(s, word_of(FS_HEAD_MAGIC), FS_MAGIC);
        st.set_word(s, word_of(FS_HEAD_VERSION), FS_VERSION);
        st.set_word(s, word_of(FS_HEAD_BLOCKS), self.blocks);
        st.set_word(s, SB_ROOT as usize, self.root);
        st.set_word(s, SB_SEQ as usize, seq);
        st.set_word(s, SB_NEXT_INO as usize, self.next_ino);
        st.set_word(s, SB_INODES as usize, self.inodes);
        let sum = head_sum(st, s);
        st.set_word(s, SB_SUM as usize, sum);
        if let Err(e) = self.store.flush() {
            self.mounted = false;
            self.store.discard();
            return Err(e);
        }
        self.seq = seq;
        self.used.remove_all(&self.freed);
        self.freed.empty();
        self.fresh.empty();
        self.committed = Head { root: self.root, next_ino: self.next_ino, inodes: self.inodes };
        Ok(())
    }

    /// Forget what this call did: the disk still holds the tree as the
    /// last commit left it.
    pub fn abort(&mut self) {
        self.store.discard();
        self.used.remove_all(&self.fresh);
        self.fresh.empty();
        self.freed.empty();
        self.root = self.committed.root;
        self.next_ino = self.committed.next_ino;
        self.inodes = self.committed.inodes;
    }

    /// How many blocks are free, counting those this call freed as used.
    pub fn free_blocks(&self) -> i64 {
        self.blocks - self.used.count(self.blocks)
    }

    /// Whether block `b` is in use.
    pub fn in_use(&self, b: i64) -> bool {
        self.used.has(b)
    }
}
