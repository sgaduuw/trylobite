//! Strings of trytes as they are, each up to ±9,841 (a code point, say),
//! not bytes: Rust's u8 would be wrong for most of them. Whole strings
//! are copied and compared by kernel/rt.s's routines, which move trytes
//! untouched; one tryte is read or written with a volatile access,
//! which detrytus ll makes a single lt or st (and LLVM can neither widen
//! nor merge), so it may only be tested against 0 or written back.

unsafe extern "C" {
    fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32;
}

/// Copy `n` trytes.
pub fn copy(from: *const u8, to: *mut u8, n: usize) {
    if n > 0 {
        unsafe { core::ptr::copy_nonoverlapping(from, to, n) }
    }
}

/// Whether the `n` trytes at `a` and `b` are the same.
pub fn same(a: *const u8, b: *const u8, n: usize) -> bool {
    unsafe { memcmp(a, b, n) == 0 }
}

/// The tryte at `p`, to test against 0 or store elsewhere.
pub fn get(p: *const u8) -> u8 {
    unsafe { p.read_volatile() }
}

/// Store a tryte `get` read.
pub fn put(p: *mut u8, t: u8) {
    unsafe { p.write_volatile(t) }
}
