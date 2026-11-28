//! stty size: say the console's size as Unix's `stty size` does, the
//! rows, a space and the columns of the terminal behind standard input
//! (IO_WINSIZE). Exit with 0; with 1 when standard input is not the
//! console or the machine does not know the size (run at a terminal, or
//! with detrytus run --console-size); with 2 for anything but `size`.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    if args.next().as_deref() != Some("size") || args.next().is_some() {
        eprintln!("usage: stty size");
        return 2;
    }
    match io::terminal_size_of(0) {
        Some((columns, rows)) => {
            println!("{rows} {columns}");
            0
        }
        None => {
            eprintln!("stty: the console's size is not known");
            1
        }
    }
}
