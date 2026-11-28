//! free: say how much memory there is, how much is in use and how much
//! is free, in pages and in trytes, on standard output, as Unix's free
//! does. In use is everything not free: the kernel, the program images,
//! the kernel's log and every process's pages. Exit with 0, or with 1 if
//! output fails.
#![no_std]

use trystd::prelude::*;
use trystd::{os, sys};

trystd::main!(run);

fn run() -> i32 {
    say().is_err() as i32
}

fn say() -> io::Result<()> {
    let info = os::info();
    let (total, free) = (info.pages() as i64, info.free_pages() as i64);
    let mut line = Line::new();
    line.str("               total        used        free").print()?;
    for (unit, label) in [(1, "pages:  "), (sys::PAGE as i64, "trytes: ")] {
        line.str(label).num_right(total * unit, 12);
        line.num_right((total - free) * unit, 12).num_right(free * unit, 12).print()?;
    }
    Ok(())
}
