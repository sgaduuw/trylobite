//! stat PATH...: what the file server knows of each PATH, as Unix's
//! stat prints it: size, blocks, type, inode, links, permissions,
//! owner, group, and the times it was last read, written and changed,
//! and made (UTC). Exit with 0, or with 1 if a PATH is not there (said
//! on standard error).
#![no_std]

use trystd::fs;
use trystd::prelude::*;
use trystd::time::{SystemTime, Utc};

trystd::main!(run);

fn run() -> i32 {
    let paths = env::args().skip(1);
    if paths.len() == 0 {
        Line::new().str("usage: stat PATH...").eprint();
        return 2;
    }
    let mut status = 0;
    for path in paths {
        let m = match fs::metadata(path) {
            Ok(m) => m,
            Err(e) => {
                Line::new().str("stat: ").str(path).str(": ").error(&e).eprint();
                status = 1;
                continue;
            }
        };
        Line::new().str("  File: ").str(path).print().ok();
        Line::new()
            .str("  Size: ")
            .num(m.len() as i64)
            .str("  Blocks: ")
            .num(m.blocks() as i64)
            .str("  ")
            .str(if m.is_dir() { "directory" } else { "regular file" })
            .print()
            .ok();
        Line::new().str(" Inode: ").num(m.ino() as i64).str("  Links: ").num(m.nlink() as i64).print().ok();
        let mut line = Line::new();
        line.str("Access: (0");
        for shift in [6, 3, 0] {
            line.byte(b'0' + ((m.mode() >> shift) & 7) as u8);
        }
        line.str(")  Uid: ").num(m.uid() as i64).str("  Gid: ").num(m.gid() as i64);
        line.print().ok();
        time("Access: ", m.accessed().ok());
        time("Modify: ", m.modified().ok());
        time("Change: ", Some(m.changed()));
        time(" Birth: ", m.created().ok());
    }
    status
}

fn time(what: &str, t: Option<SystemTime>) {
    let Some(t) = t else { return };
    let u = Utc::from_system_time(t);
    let mut line = Line::new();
    line.str(what).num(u.year).str("-");
    two(&mut line, u.month).str("-");
    two(&mut line, u.day).str(" ");
    two(&mut line, u.hour).str(":");
    two(&mut line, u.minute).str(":");
    two(&mut line, u.second).str(".");
    let ns = t.subsec_nanos();
    let mut d = 100_000_000;
    while d > 0 {
        line.byte(b'0' + (ns / d % 10) as u8);
        d /= 10;
    }
    line.str(" +0000").print().ok();
}

fn two(line: &mut Line, n: u32) -> &mut Line {
    if n < 10 {
        line.str("0");
    }
    line.num(n as i64)
}
