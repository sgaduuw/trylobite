//! uptime: say how long the machine has run, and how busy it is, on
//! standard output, as Unix's uptime does. The machine has no seconds:
//! its clock counts ticks, one per step of the machine (detrytus
//! docs/platform.md, Time). Exit with 0, or with 1 if output fails.
#![no_std]

use trystd::os;
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let info = os::info();
    let harts = info.harts();
    let mut line = Line::new();
    line.str("up ").num(info.time()).str(" ticks, ").num(info.processes() as i64);
    line.str(" processes, ").num(harts as i64);
    line.str(if harts == 1 { " hart" } else { " harts" });
    line.print().is_err() as i32
}
