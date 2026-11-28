//! stty size: say the console's size as Unix's `stty size` does, the
//! rows, a space and the columns of the terminal behind standard input
//! (IO_WINSIZE). Exit with 0; with 1 when standard input is not the
//! console or the machine does not know the size (run at a terminal, or
//! with detrytus run --console-size), or output fails; with 2 for
//! anything but `size`.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let mut line = Line::new();
    if args.next() != Some("size") || args.next().is_some() {
        line.str("usage: stty size").eprint();
        return 2;
    }
    match io::terminal_size_of(0) {
        Some((columns, rows)) => {
            line.num(rows as i64).byte(b' ').num(columns as i64);
            line.print().is_err() as i32
        }
        None => {
            line.str("stty: the console's size is not known").eprint();
            1
        }
    }
}
