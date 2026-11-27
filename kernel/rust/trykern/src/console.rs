//! The kernel's own messages, for the Rust: kernel/console.s prints and
//! keeps the log, and these call it.

use crate::word::Word;

unsafe extern "C" {
    /// kernel/console.s: print code point a0.
    fn kputc(c: i32);
    /// kernel/console.s: print the 0-ended string of trytes at a0.
    fn kputs(s: *const u8);
}

/// Print code point `c`.
pub fn putc(c: i32) {
    unsafe { kputc(c) }
}

/// Print the kernel's 0-ended string at `s` (a `msg_` of kernel/data.s).
pub fn puts(s: *const u8) {
    unsafe { kputs(s) }
}

/// Print `n` in decimal. Most of what the kernel prints fits an i32: a
/// count, a hart, a page or 2·10⁹ trytes at most.
pub fn putn(n: i32) {
    if n < 0 {
        putc(b'-' as i32);
    }
    // Digits from the lowest, as negatives: -i32::MIN does not fit.
    let mut digits = [0u8; 10];
    let mut k = 0;
    let mut m = if n < 0 { n } else { -n };
    loop {
        digits[k] = (b'0' as i32 - m % 10) as u8;
        k += 1;
        m /= 10;
        if m == 0 {
            break;
        }
    }
    while k > 0 {
        k -= 1;
        putc(digits[k] as i32);
    }
}

/// Print word `w` in decimal, as an exit code may be any word: 64-bit
/// arithmetic, helper calls and all, unless it fits an i32.
pub fn putw(w: Word) {
    if w >= i32::MIN as Word && w <= i32::MAX as Word {
        return putn(w as i32);
    }
    if w < 0 {
        putc(b'-' as i32);
    }
    let mut digits = [0u8; 20];
    let mut k = 0;
    let mut m = if w < 0 { w } else { -w };
    while m != 0 {
        digits[k] = (b'0' as Word - m % 10) as u8;
        k += 1;
        m /= 10;
    }
    while k > 0 {
        k -= 1;
        putc(digits[k] as i32);
    }
}
