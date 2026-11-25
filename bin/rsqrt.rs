//! rsqrt [N]: the square roots of 1 to N (10 if not given, at most 99),
//! found by Newton's method in f64 and printed with `{}`, as the
//! shortest decimal that reads back as the same f64, then as an f32.
//! Core's float formatting (Grisu, with Dragon to fall back on) is a
//! program of several blocks.
#![no_std]

#[path = "../lib/rust/sys.rs"]
mod sys;

/// The number from 1 to 99 in `arg`, if it is one.
fn number(arg: &[u8]) -> Option<u32> {
    let mut n: u32 = 0;
    for &c in arg {
        if !c.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (c - b'0') as u32;
        if n > 99 {
            return None;
        }
    }
    if n >= 1 { Some(n) } else { None }
}

/// The square root of `x`, at least 1, by Newton's method: from x, each
/// step averages the guess with x over it, until a step no longer
/// brings it down.
fn sqrt(x: f64) -> f64 {
    let mut r = x;
    loop {
        let next = (r + x / r) / 2.0;
        if next >= r {
            return r;
        }
        r = next;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: i32, argv: *const *const u8) -> i32 {
    let n = match sys::args(argc, argv).nth(1) {
        None => 10,
        Some(a) => match number(a) {
            Some(n) => n,
            None => {
                eprintln!("usage: rsqrt [N], N from 1 to 99");
                return 1;
            }
        },
    };
    for k in 1..=n {
        let r = sqrt(k as f64);
        println!("sqrt({k}) = {r} ({})", r as f32);
    }
    0
}
