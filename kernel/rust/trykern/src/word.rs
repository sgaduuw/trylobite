//! Words: what the machine moves, 27 trits, and what Rust cannot name.
//! A word is an i64 on the Rust side (detrytus docs/rust.md, "Words and
//! the machine"), and the builtins below are single instructions.

/// A machine word's value, ±(3^27 − 1)/2 at most.
pub type Word = i64;

unsafe extern "C" {
    #[link_name = "detrytus.lw"]
    fn lw(p: *const u8) -> Word;
    #[link_name = "detrytus.sw"]
    fn sw(p: *mut u8, w: Word);
    #[link_name = "detrytus.csrr"]
    fn csrr(csr: i32) -> Word;
}

/// The wall clock, the `time` CSR (detrytus isa.md 8.2).
const CSR_TIME: i32 = -8747;

/// The kernel address a word holds, as a pointer. Every kernel address
/// is within ±2^31 (include/layout.s, MEM_MAX), so the i32 keeps it.
pub fn addr(w: Word) -> *mut u8 {
    w as i32 as isize as *mut u8
}

/// The word at `p`, which must be aligned.
pub fn load(p: *const u8) -> Word {
    unsafe { lw(p) }
}

/// Store `w` in the word at `p`, which must be aligned.
pub fn store(p: *mut u8, w: Word) {
    unsafe { sw(p, w) }
}

/// The word `off` trytes from `p`.
pub fn load_at(p: *const u8, off: Word) -> Word {
    load(p.wrapping_offset(off as isize))
}

/// Store `w` in the word `off` trytes from `p`.
pub fn store_at(p: *mut u8, off: Word, w: Word) {
    store(p.wrapping_offset(off as isize), w)
}

/// The wall clock in ticks.
pub fn time() -> Word {
    unsafe { csrr(CSR_TIME) }
}
