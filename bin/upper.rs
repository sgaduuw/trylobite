//! upper: copy standard input to standard output with a to z made A to
//! Z, until the input ends; exit with 0, or with 1 if output fails. A
//! filter, for the end of a pipe: hello | upper.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    copy().is_err() as i32
}

fn copy() -> io::Result<()> {
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut buf = [0u8; 243];
    loop {
        let n = stdin.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        buf[..n].make_ascii_uppercase();
        stdout.write_all(&buf[..n])?;
        stdout.flush()?;
    }
}
