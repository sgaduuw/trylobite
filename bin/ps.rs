//! ps: say each process on standard output, a line each, as Unix's ps
//! does: its number, its parent's, its state, the pages it holds, the
//! ticks it has run in user mode and its name. Every process, since
//! there are no users or terminals to choose by. Exit with 0, or with 1
//! if output fails.
#![no_std]

use trystd::os;
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    list().is_err() as i32
}

fn list() -> io::Result<()> {
    let mut line = Line::new();
    line.str("  PID  PPID STATE    PAGES       TIME NAME").print()?;
    for (pid, p) in os::processes() {
        line.num_right(pid as i64, 5);
        match p.parent {
            Some(n) => line.num_right(n as i64, 6),
            None => line.str("     -"),
        };
        line.byte(b' ').str_left(p.state.name(), 7);
        line.num_right(p.pages as i64, 6).num_right(p.cpu, 11).byte(b' ');
        line.str(if p.name().is_empty() { "-" } else { p.name() }).print()?;
    }
    Ok(())
}
