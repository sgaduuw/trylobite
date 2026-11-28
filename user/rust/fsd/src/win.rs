//! The file server's store: its NWIN block windows, which the disk
//! server reads blocks into and writes them from, a call each. They are
//! a cache: the window used least recently goes when another block is
//! needed, a clean one first, else a dirty one written out early (only
//! ever a fresh block or a new data block, which the disk's tree does
//! not point to yet, so writing it early is safe; tryfs's store.rs).

use tryfs::layout::*;
use tryfs::{Result, Slot, Store};

use crate::sys;

const NW: usize = NWIN as usize;
const NONE: i64 = -1;

#[derive(Clone, Copy)]
struct Win {
    block: i64,
    used: u32,
    dirty: bool,
    checked: bool,
    node: bool,
}

pub struct Windows {
    /// The disk server's process.
    pub disk: i64,
    w: [Win; NW],
    clock: u32,
    seq: i64,
    made: u32, // a bit for each window SYS_WINDOW has made
}

/// Window `k`'s centre, as the disk server and spawnw take it.
#[inline(always)]
pub fn centre(k: usize) -> i64 {
    V_BLOCK + PAGE * k as i64
}

/// Window `k`'s first word.
#[inline(always)]
fn base(k: usize) -> *mut u8 {
    (centre(k) + BLOCK_W0) as usize as *mut u8
}

/// Window `k`'s first tryte, where a file's data starts.
pub fn first_tryte(k: usize) -> i64 {
    centre(k) + BLOCK_T0
}

impl Windows {
    pub const fn new() -> Windows {
        let none = Win { block: NONE, used: 0, dirty: false, checked: false, node: false };
        Windows { disk: E_NOPROC, w: [none; NW], clock: 0, seq: 0, made: 0 }
    }

    fn touch(&mut self, k: usize) {
        self.clock += 1;
        self.w[k].used = self.clock;
    }

    fn find(&self, b: i64) -> Option<usize> {
        (0..NW).find(|&k| self.w[k].block == b)
    }

    /// Make window `k` if it is not there yet.
    fn make(&mut self, k: usize) -> Result<()> {
        if self.made & (1 << k) == 0 {
            let r = sys::call(SYS_WINDOW, k as i64, 0, 0, 0, 0);
            if r < 0 {
                return Err(r);
            }
            self.made |= 1 << k;
        }
        Ok(())
    }

    fn disk_call(&self, op: i64, b: i64, k: usize) -> Result<()> {
        if sys::call(SYS_CALL, self.disk, op, b, centre(k), 0) != 0 {
            return Err(E_IO);
        }
        Ok(())
    }

    /// Write window `k`'s block, sealing it first if it is a node.
    fn write(&mut self, k: usize) -> Result<()> {
        if self.w[k].node {
            tryfs::node::seal(self, k, self.seq);
        }
        self.disk_call(DK_WRITE, self.w[k].block, k)?;
        self.w[k].dirty = false;
        Ok(())
    }

    /// A window to put a new block in: the clean one used least
    /// recently, else the dirty one used least recently, written out.
    fn victim(&mut self) -> Result<usize> {
        let mut best: Option<usize> = None;
        for k in 0..NW {
            if !self.w[k].dirty && best.is_none_or(|b| self.w[k].used < self.w[b].used) {
                best = Some(k);
            }
        }
        if best.is_none() {
            for k in 0..NW {
                if self.w[k].block != 0 && best.is_none_or(|b| self.w[k].used < self.w[b].used) {
                    best = Some(k);
                }
            }
            let k = best.ok_or(E_IO)?;
            self.write(k)?;
        }
        let k = best.ok_or(E_IO)?;
        self.make(k)?;
        Ok(k)
    }

    /// Read block `b` into window `k`, which must not be dirty: what it
    /// held is dropped, and so is any other window's copy of `b`.
    pub fn read_into(&mut self, b: i64, k: usize) -> Result<()> {
        if self.w[k].block == b {
            self.touch(k);
            return Ok(());
        }
        if let Some(other) = self.find(b) {
            if self.w[other].dirty {
                self.write(other)?;
            }
            self.w[other].block = NONE;
        }
        self.make(k)?;
        self.w[k].block = NONE; // nothing, unless the read works
        self.w[k].dirty = false;
        self.disk_call(DK_READ, b, k)?;
        self.w[k] = Win { block: b, used: 0, dirty: false, checked: false, node: false };
        self.touch(k);
        Ok(())
    }

    /// Say that the block in window `k` changed by other means (a copyin).
    pub fn mark_dirty(&mut self, k: usize) {
        self.w[k].dirty = true;
    }
}

impl Store for Windows {
    fn load(&mut self, b: i64) -> Result<Slot> {
        if let Some(k) = self.find(b) {
            self.touch(k);
            return Ok(k);
        }
        let k = self.victim()?;
        self.read_into(b, k)?;
        Ok(k)
    }

    fn zero(&mut self, b: i64) -> Result<Slot> {
        let k = match self.find(b) {
            Some(k) => k,
            None => self.victim()?,
        };
        let p = base(k).wrapping_sub(1); // the first tryte
        unsafe { core::ptr::write_bytes(p, 0, 3 * BLOCK_WORDS as usize) };
        self.w[k] = Win { block: b, used: 0, dirty: true, checked: true, node: false };
        self.touch(k);
        Ok(k)
    }

    #[inline(always)]
    fn word(&self, s: Slot, i: usize) -> i64 {
        sys::word(base(s), i)
    }

    fn sum_words(&self, s: Slot, n: usize, skip: usize) -> i64 {
        debug_assert_eq!(skip, tryfs::layout::N_SUM as usize);
        sys::sum(base(s), n)
    }

    fn set_word(&mut self, s: Slot, i: usize, w: i64) {
        sys::set_word(base(s), i, w);
        self.w[s].dirty = true;
    }

    fn move_words(&mut self, s: Slot, from: usize, to: usize, n: usize) {
        let p = base(s).wrapping_sub(1); // the first tryte
        unsafe { core::ptr::copy(p.wrapping_add(3 * from), p.wrapping_add(3 * to), 3 * n) };
        self.w[s].dirty = true;
    }

    fn copy_words(&mut self, a: Slot, from: usize, b: Slot, to: usize, n: usize) {
        let pa = base(a).wrapping_sub(1);
        let pb = base(b).wrapping_sub(1);
        unsafe { core::ptr::copy_nonoverlapping(pa.wrapping_add(3 * from), pb.wrapping_add(3 * to), 3 * n) };
        self.w[b].dirty = true;
    }

    fn copy_to(&mut self, s: Slot, to: i64) -> Result<Slot> {
        if let Some(other) = self.find(to) {
            if other != s {
                self.w[other].block = NONE;
                self.w[other].dirty = false;
            }
        }
        self.w[s].block = to;
        self.w[s].dirty = true;
        self.w[s].checked = true;
        self.touch(s);
        Ok(s)
    }

    fn forget(&mut self, b: i64) {
        if let Some(k) = self.find(b) {
            self.w[k].block = NONE;
            self.w[k].dirty = false;
        }
    }

    fn checked(&self, s: Slot) -> bool {
        self.w[s].checked
    }

    fn set_checked(&mut self, s: Slot) {
        self.w[s].checked = true;
    }

    fn set_node(&mut self, s: Slot) {
        self.w[s].node = true;
    }

    fn set_seq(&mut self, seq: i64) {
        self.seq = seq;
    }

    fn flush(&mut self) -> Result<()> {
        let mut result = Ok(());
        for k in 0..NW {
            if self.w[k].dirty && self.w[k].block != 0 {
                if let Err(e) = self.write(k) {
                    result = Err(e);
                }
            }
        }
        result?;
        if let Some(k) = self.find(0) {
            if self.w[k].dirty {
                self.write(k)?;
            }
        }
        Ok(())
    }

    fn discard(&mut self) {
        for w in self.w.iter_mut() {
            if w.dirty {
                w.block = NONE;
                w.dirty = false;
            }
        }
    }
}
