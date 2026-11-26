//! recho: echo in Rust. Say the arguments after the command on standard
//! output, a space between each and a newline after; exit with 0, or
//! with 1 if output fails.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> io::Result<()> {
    let mut out = io::stdout();
    for (i, arg) in env::args_bytes().enumerate().skip(1) {
        if i > 1 {
            out.write_all(b" ")?;
        }
        out.write_all(arg)?;
    }
    out.write_all(b"\n")
}
