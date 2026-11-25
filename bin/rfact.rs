//! rfact [N]: the factorials from 1! to N! (20 if not given, and at
//! most 34, the last that fits a u128), in a table. Rust's println! and
//! 128-bit integers on trytes, through core::fmt.
#![no_std]

#[path = "../lib/rust/sys.rs"]
mod sys;

/// The number from 1 to 34 in `arg`, if it is one.
fn number(arg: &[u8]) -> Option<u128> {
    let mut n: u128 = 0;
    for &c in arg {
        if !c.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (c - b'0') as u128;
        if n > 34 {
            return None;
        }
    }
    if n >= 1 { Some(n) } else { None }
}

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: i32, argv: *const *const u8) -> i32 {
    let n = match sys::args(argc, argv).nth(1) {
        None => 20,
        Some(a) => match number(a) {
            Some(n) => n,
            None => {
                eprintln!("usage: rfact [N], N from 1 to 34");
                return 1;
            }
        },
    };
    let mut f: u128 = 1;
    for k in 1..=n {
        f = f.wrapping_mul(k);
        println!("{k:>2}! = {f:>39}");
    }
    0
}
