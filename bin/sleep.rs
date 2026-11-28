//! sleep TICKS | sleep TIME: wait, then exit with 0. A bare number is
//! ticks of the machine's clock, one per step (detrytus
//! docs/platform.md, Time); a number with a unit, `s`, `ms` or `us`
//! (`sleep 2s`, `sleep 1.5s`, `sleep 250ms`), is real time, as Unix's
//! sleep waits seconds, measured by the monotonic clock. Exit with 2 for
//! no number or a bad one.
#![no_std]

use trystd::prelude::*;
use trystd::sys;
use trystd::time::Duration;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let arg = match (args.next(), args.next()) {
        (Some(a), None) => a,
        _ => return usage(),
    };
    // Whole numbers of at most 9 digits, so that the sums and divisions
    // are u32s: a 64-bit division is a helper of some 3,000 steps.
    let digits = arg.bytes().take_while(|b| b.is_ascii_digit()).count();
    let (whole, rest) = arg.split_at(digits);
    if whole.is_empty() || whole.len() > 9 {
        return usage();
    }
    let n = whole.bytes().fold(0u32, |t, b| t * 10 + (b - b'0') as u32);
    if rest.is_empty() {
        sys::sleep_until(sys::ticks() + n as i64);
        return 0;
    }
    let (fraction, unit) = match rest.strip_prefix('.') {
        Some(r) => {
            let k = r.bytes().take_while(|b| b.is_ascii_digit()).count();
            if k == 0 {
                return usage();
            }
            r.split_at(k)
        }
        None => ("", rest),
    };
    let (per, in_second): (u32, u32) = match unit {
        "s" => (1_000_000_000, 1),
        "ms" => (1_000_000, 1_000),
        "us" => (1_000, 1_000_000),
        _ => return usage(),
    };
    let mut nanos = n % in_second * per;
    let mut part = per;
    for b in fraction.bytes() {
        part /= 10;
        nanos += (b - b'0') as u32 * part;
    }
    trystd::thread::sleep(Duration::new((n / in_second) as u64, nanos));
    0
}

fn usage() -> i32 {
    Line::new().str("usage: sleep TICKS | sleep NUMBER{s|ms|us}").eprint();
    2
}
