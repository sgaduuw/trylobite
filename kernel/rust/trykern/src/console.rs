//! The kernel's own messages, for the Rust: kernel/console.s prints and
//! keeps the log, and these call it.

unsafe extern "C" {
    /// kernel/console.s: print code point a0.
    fn kputc(c: i32);
    /// kernel/console.s: print the 0-ended string of trytes at a0.
    fn kputs(s: *const u8);
}

/// Print code point `c`.
pub fn putc(c: u8) {
    unsafe { kputc(c as i32) }
}

/// Print the kernel's 0-ended string at `s` (a `msg_` of kernel/data.s).
pub fn puts(s: *const u8) {
    unsafe { kputs(s) }
}

/// Print `n` in decimal. What the kernel prints fits an i32: a count, a
/// hart, a page or 2·10⁹ trytes at most.
pub fn putn(n: i32) {
    if n < 0 {
        putc(b'-');
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
        putc(digits[k]);
    }
}
