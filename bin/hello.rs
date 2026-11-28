//! hello: say hello on standard output, and exit with 0; with nothing
//! there, exit with 1. The smallest program of bin/.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut out = io::stdout();
    let said = out.write_all(b"hello from a balanced-ternary machine\n");
    said.and_then(|()| out.flush()).is_err() as i32
}
