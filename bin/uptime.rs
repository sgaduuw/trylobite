//! uptime: say how long the machine has run, and how busy it is, on
//! standard output, as Unix's uptime does: the time since it started by
//! the monotonic clock, [D days, ]HH:MM:SS, which setting the time of
//! day does not change, then the ticks its clock has counted, one per
//! step of the machine (detrytus docs/platform.md, Time). Exit with 0,
//! or with 1 if output fails.
#![no_std]

use trystd::os;
use trystd::prelude::*;
use trystd::time;

trystd::main!(run);

fn run() -> i32 {
    let info = os::info();
    let harts = info.harts();
    // Seconds fit a u32 for 136 years, and u32s divide cheaply.
    let up = time::uptime().as_secs().min(u32::MAX as u64) as u32;
    let mut line = Line::new();
    line.str("up ");
    let days = up / 86_400;
    if days > 0 {
        line.num(days as i64).str(if days == 1 { " day, " } else { " days, " });
    }
    let rest = up % 86_400;
    two(&mut line, rest / 3600).byte(b':');
    two(&mut line, rest / 60 % 60).byte(b':');
    two(&mut line, rest % 60);
    line.str(", ").num(info.time()).str(" ticks, ").num(info.processes() as i64);
    line.str(" processes, ").num(harts as i64);
    line.str(if harts == 1 { " hart" } else { " harts" });
    line.print().is_err() as i32
}

/// `n`, under 100, in two digits.
fn two(line: &mut Line, n: u32) -> &mut Line {
    line.byte(b'0' + (n / 10) as u8).byte(b'0' + (n % 10) as u8)
}
