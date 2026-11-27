//! A process record, the PCB_ words kernel/*.s keeps for each slot of
//! the process table (include/layout.s). The layout stays defined in
//! assembly; Rust reaches a field by its offset.

use crate::harts::wake_one;
use crate::kdata;
use crate::layout::*;
use crate::word::{Word, load_at, load_small_at, store_at};

/// A process's record, by address.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Proc(pub *mut u8);

impl Proc {
    /// Process `pid`'s record, which must be in the table's range.
    pub fn of(pid: Word) -> Proc {
        // In 32 bits: a 64-bit multiplication is a helper call.
        Proc(kdata::procs_base().wrapping_offset((pid as i32 * PCB_SIZE as i32) as isize))
    }

    /// Process `pid`'s record if it is alive: neither a free slot nor
    /// ended.
    pub fn alive(pid: Word) -> Option<Proc> {
        if pid < 0 || pid >= NPROC {
            return None;
        }
        let p = Proc::of(pid);
        (!p.is(ST_EXITED) && !p.is(ST_ZOMBIE)).then_some(p)
    }

    /// Every slot of the process table, free ones included.
    pub fn table() -> Table {
        let (at, end) = Proc::bounds();
        Table { at, end }
    }

    /// The process table's first record and the address just past it.
    pub fn bounds() -> (*mut u8, *mut u8) {
        let base = kdata::procs_base();
        (base, base.wrapping_offset((NPROC * PCB_SIZE) as isize))
    }

    /// The process's number.
    pub fn pid(self) -> Word {
        ((self.0 as isize - kdata::procs_base() as isize) as i32 / PCB_SIZE as i32) as Word
    }

    /// The record's address as a word, as the assembly keeps records
    /// in tables (such as drivers).
    pub fn addr_word(self) -> Word {
        self.0 as isize as Word
    }

    /// The record's PCB_ word at `field`.
    pub fn get(self, field: Word) -> Word {
        load_at(self.0, field)
    }

    /// The process's PCB_STATE, read as the small number every state
    /// is: tables are scanned for states on every switch.
    pub fn state(self) -> i32 {
        load_small_at(self.0, PCB_STATE)
    }

    /// Whether the process is in `state`.
    pub fn is(self, state: Word) -> bool {
        self.state() == state as i32
    }

    /// Set the record's PCB_ word at `field`.
    pub fn set(self, field: Word, w: Word) {
        store_at(self.0, field, w)
    }

    /// The address `off` trytes into the record.
    pub fn at(self, off: Word) -> *mut u8 {
        self.0.wrapping_offset(off as isize)
    }

    /// Set the record's tryte at `off` (such as a PCB_CLOSED flag) to a
    /// small number.
    pub fn set_tryte(self, off: Word, v: u8) {
        unsafe { self.at(off).write_volatile(v) }
    }

    /// Make it ready and ring a hart for it.
    pub fn ready(self) {
        if self.is(ST_CALL) {
            // Its call is off (killed, or the server ended): the server
            // counts one caller fewer.
            let q = Proc::of(self.get(PCB_PEER));
            q.set(PCB_CALLERS, q.get(PCB_CALLERS) - 1);
        }
        if !self.is(ST_READY) {
            kdata::write::nready(kdata::read::nready() + 1);
        }
        self.set(PCB_STATE, ST_READY);
        wake_one();
    }

    /// A notice waits for it (an interrupt, its alarm, a closed handle,
    /// a notification, an ending): note that receive should look, and
    /// wake it if it sleeps in receive.
    pub fn rouse(self) {
        self.set(PCB_PENDING, 1);
        self.retry_if(ST_RECEIVE);
    }

    /// Wake it if it sleeps in `state`, to run its system call again
    /// (PCB_RETRY): rouse, for ST_RECEIVE.
    pub fn retry_if(self, state: Word) {
        if self.is(state) {
            self.set(PCB_RETRY, 1);
            self.ready();
        }
    }
}

/// The process table's slots in order (Proc::table). Its own iterator,
/// stepping a pointer and inlined: a range mapped to records was a call
/// for each slot, in loops pick and the idle check run on every switch.
pub struct Table {
    at: *mut u8,
    end: *mut u8,
}

impl Iterator for Table {
    type Item = Proc;

    #[inline(always)]
    fn next(&mut self) -> Option<Proc> {
        if self.at >= self.end {
            return None;
        }
        let p = Proc(self.at);
        self.at = self.at.wrapping_offset(PCB_SIZE as isize);
        Some(p)
    }
}
