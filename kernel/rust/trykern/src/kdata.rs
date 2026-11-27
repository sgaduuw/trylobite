//! The kernel's globals, defined in kernel/data.s and reached by name.
//! Each is a word (or, for `kversion`, a string of trytes); Rust sees
//! only its address.

unsafe extern "C" {
    static ticks: u8;
    static ram_pages: u8;
    static free_count: u8;
    static log_base: u8;
    static log_pos: u8;
    static procs: u8;
    static kversion: u8;
    static names: u8;
}

macro_rules! word_of {
    ($($name:ident),*) => {$(
        pub fn $name() -> Word {
            load(unsafe { &raw const super::$name })
        }
    )*};
}

// Each is read under the kernel lock, which every system call holds.
pub mod read {
    use crate::word::{Word, load};
    word_of!(ticks, ram_pages, free_count, log_base, log_pos);
}

/// The process table's first record.
pub fn procs_base() -> *mut u8 {
    (&raw const procs).cast_mut()
}

/// The kernel's version, a 0-ended string of trytes.
pub fn version() -> *const u8 {
    &raw const kversion
}

/// The server names' first record (names.rs).
pub fn names_base() -> *mut u8 {
    (&raw const names).cast_mut()
}
