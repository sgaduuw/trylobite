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
    static sleepers: u8;
    static next_wake: u8;
    static clock_secs: u8;
    static clock_us: u8;
    static nready: u8;
    static nidle: u8;
    static irq_armed: u8;
    static drivers: u8;
    static free_head: u8;
    static fresh_page: u8;
    static next_slot: u8;
    static nprog: u8;
    static epochs: u8;
    static fpu_owner: u8;
    static idle_harts: u8;
    static leaving: u8;
}

macro_rules! word_of {
    ($($name:ident),*) => {$(
        #[inline(always)]
        pub fn $name() -> Word {
            load(unsafe { &raw const super::$name })
        }
    )*};
}

// Each is read under the kernel lock, which every system call holds.
pub mod read {
    use crate::word::{Word, load};
    word_of!(
        ticks, ram_pages, free_count, log_base, log_pos, sleepers, next_wake, irq_armed, free_head,
        fresh_page, next_slot, nprog, nready, nidle, clock_secs, clock_us
    );
}

macro_rules! set_word_of {
    ($($name:ident),*) => {$(
        #[inline(always)]
        pub fn $name(w: Word) {
            store(unsafe { &raw const super::$name }.cast_mut(), w)
        }
    )*};
}

// ... and written under it.
pub mod write {
    use crate::word::{Word, store};
    set_word_of!(
        sleepers, next_wake, ram_pages, free_count, free_head, fresh_page, next_slot, irq_armed,
        nready, nidle, clock_secs, clock_us
    );
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

/// Each interrupt source's driver's record, or 0: NSRC words (devices.rs).
pub fn drivers_base() -> *mut u8 {
    (&raw const drivers).cast_mut()
}

/// Each slot's tenants so far: NPROC words (see resume).
pub fn epochs_base() -> *mut u8 {
    (&raw const epochs).cast_mut()
}

/// Whose bank each hart's coprocessor holds, a record or 0: NHART words.
pub fn fpu_owner_base() -> *mut u8 {
    (&raw const fpu_owner).cast_mut()
}

/// 1 for each hart that waits for work, by hart + HART_MAX: NHART words.
pub fn idle_harts_base() -> *mut u8 {
    (&raw const idle_harts).cast_mut()
}

/// 1 for each hart the platform asked to go, by hart + HART_MAX.
pub fn leaving_base() -> *mut u8 {
    (&raw const leaving).cast_mut()
}
