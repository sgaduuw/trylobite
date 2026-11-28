//! echo: say the arguments after the command on standard output, a space
//! between each and a newline after, as Unix's echo does; exit with 0,
//! or with 1 if output fails.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

// Returning a code, not an io::Result, keeps core::fmt (which would say
// the error) out: echo is a third of the size for it.
fn run() -> i32 {
    say().is_err() as i32
}

fn say() -> io::Result<()> {
    let mut out = io::stdout();
    for (i, arg) in env::args_bytes().enumerate().skip(1) {
        if i > 1 {
            out.write_all(b" ")?;
        }
        out.write_all(arg)?;
    }
    out.write_all(b"\n")?;
    out.flush()
}
