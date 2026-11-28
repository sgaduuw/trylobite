//! dmesg: say the kernel's log on standard output: what it printed
//! since boot, as far back as it keeps (LOG_SIZE code points), as Unix's
//! dmesg prints the kernel's message buffer. The boot report is there,
//! init's lines, and every process's ending. Exit with 0, or with 1 if
//! output fails.
#![no_std]

use trystd::os;
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    copy().is_err() as i32
}

fn copy() -> io::Result<()> {
    let mut out = io::stdout();
    let mut buf = [0u8; 243];
    let mut from = 0;
    loop {
        let (n, next) = os::read_log(&mut buf, from)?;
        if n == 0 {
            return out.flush();
        }
        out.write_all(&buf[..n])?;
        from = next;
    }
}
