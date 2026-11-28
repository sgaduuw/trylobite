//! fail: exit with code 3 at once, so the shell has something to report.
#![no_std]

trystd::main!(run);

fn run() -> i32 {
    3
}
