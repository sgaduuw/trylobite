//! A process record, the PCB_ words kernel/*.s keeps for each slot of
//! the process table (include/layout.s). The layout stays defined in
//! assembly; Rust reaches a field by its offset.

use crate::word::{Word, load_at, store_at};

/// A process's record, by address.
#[derive(Clone, Copy)]
pub struct Proc(pub *mut u8);

impl Proc {
    /// The record's PCB_ word at `field`.
    pub fn get(self, field: Word) -> Word {
        load_at(self.0, field)
    }

    /// Set the record's PCB_ word at `field`.
    pub fn set(self, field: Word, w: Word) {
        store_at(self.0, field, w)
    }
}
