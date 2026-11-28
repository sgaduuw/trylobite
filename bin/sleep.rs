//! sleep TICKS: wait that many ticks of the clock, then exit with 0, as
//! Unix's sleep waits seconds. The clock counts one tick per step of
//! the machine (detrytus docs/platform.md, Time). Exit with 2 for no
//! number or a bad one.
#![no_std]

use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let ticks = match (args.next(), args.next()) {
        (Some(n), None) if !n.is_empty() && n.len() <= 18 && n.bytes().all(|b| b.is_ascii_digit()) => {
            n.bytes().fold(0i64, |t, b| t * 10 + (b - b'0') as i64)
        }
        _ => {
            Line::new().str("usage: sleep TICKS").eprint();
            return 2;
        }
    };
    sys::sleep_until(sys::ticks() + ticks);
    0
}
