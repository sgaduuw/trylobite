//! uname [-a]: say the system's name on standard output, as Unix's
//! uname does; with -a also the kernel's version and the machine. Exit
//! with 0, with 1 if output fails, or with 2 for an argument it does not
//! know (said on standard error).
#![no_std]

use trystd::os;
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let mut line = Line::new();
    match (args.next(), args.next()) {
        (None, _) => line.str("trylobite"),
        (Some("-a"), None) => line.str("trylobite ").str(os::info().release()).str(" detrytus"),
        _ => {
            line.str("usage: uname [-a]").eprint();
            return 2;
        }
    };
    line.print().is_err() as i32
}
