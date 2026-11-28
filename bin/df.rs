//! df: say how full the disk is, on standard output, as Unix's df does:
//! its blocks (a page each) used and free, the share used, and its
//! inodes (files and directories) and how many are free. There is one
//! disk, the file server's, holding /. Exit with 0, with 1 if output
//! fails, or with 2 if there is no filesystem (said on standard error).
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let Ok(s) = fs::statfs() else {
        Line::new().str("df: no filesystem").eprint();
        return 2;
    };
    let used = s.blocks - s.blocks_free;
    // The share used, rounded up as Unix's df does.
    let share = if s.blocks > 0 { (used * 100 + s.blocks - 1) / s.blocks } else { 0 };
    let mut line = Line::new();
    line.str("Filesystem    Blocks     Used     Free  Use%   Inodes    IFree  Mounted on");
    let said = line.print().and_then(|()| {
        line.str("disk0      ").num_right(s.blocks as i64, 9).num_right(used as i64, 9);
        line.num_right(s.blocks_free as i64, 9).num_right(share as i64, 5).byte(b'%');
        line.num_right(s.inodes as i64, 9).num_right(s.inodes_free as i64, 9).str("  /");
        line.print()
    });
    said.is_err() as i32
}
