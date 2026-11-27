//! A process record, the PCB_ words kernel/*.s keeps for each slot of
//! the process table (include/layout.s). The layout stays defined in
//! assembly; Rust reaches a field by its offset.

use crate::kdata;
use crate::layout::*;
use crate::word::{Word, load_at, store_at};

unsafe extern "C" {
    /// kernel/harts.s: ring one idle hart, as something became ready.
    fn wake_one();
}

/// A process's record, by address.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Proc(pub *mut u8);

impl Proc {
    /// Process `pid`'s record, which must be in the table's range.
    pub fn of(pid: Word) -> Proc {
        Proc(kdata::procs_base().wrapping_offset((pid * PCB_SIZE) as isize))
    }

    /// Process `pid`'s record if it is alive: neither a free slot nor
    /// ended (proc_of in kernel/ipc.s).
    pub fn alive(pid: Word) -> Option<Proc> {
        if !(0..NPROC).contains(&pid) {
            return None;
        }
        let p = Proc::of(pid);
        let state = p.get(PCB_STATE);
        (state != ST_EXITED && state != ST_ZOMBIE).then_some(p)
    }

    /// Every slot of the process table, free ones included.
    pub fn table() -> impl Iterator<Item = Proc> {
        (0..NPROC).map(Proc::of)
    }

    /// The process's number.
    pub fn pid(self) -> Word {
        (self.0 as isize - kdata::procs_base() as isize) as Word / PCB_SIZE
    }

    /// The record's PCB_ word at `field`.
    pub fn get(self, field: Word) -> Word {
        load_at(self.0, field)
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
        self.set(PCB_STATE, ST_READY);
        unsafe { wake_one() }
    }

    /// Wake it if it sleeps in `state`, to run its system call again
    /// (PCB_RETRY): rouse in kernel/ipc.s for ST_RECEIVE.
    pub fn retry_if(self, state: Word) {
        if self.get(PCB_STATE) == state {
            self.set(PCB_RETRY, 1);
            self.ready();
        }
    }
}
