//! mv FROM TO, mv FROM... DIR: give file or directory FROM the name TO,
//! replacing a file of that name, or move each FROM into directory DIR
//! under its own last name, as Unix's mv does. A rename in the file
//! server (FS_RENAME), so nothing is copied. Exit with 0, or with 1 if
//! anything fails (said on standard error).
#![no_std]

use trystd::fs;
use trystd::io::ErrorKind;
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

/// Room for a path, on the stack: the tools keep off the heap, so that
/// they need a page less.
type PathBuf = [u8; sys::PATH_MAX as usize + 1];

/// `dir`/the last name of `from`, made in `buf`; None if it is longer
/// than a path may be.
fn into<'a>(buf: &'a mut PathBuf, dir: &str, from: &str) -> Option<&'a str> {
    let last = from.trim_end_matches('/').rsplit('/').next().unwrap_or(from);
    let slash = if dir.ends_with('/') { "" } else { "/" };
    let mut n = 0;
    for part in [dir, slash, last] {
        buf.get_mut(n..n + part.len())?.copy_from_slice(part.as_bytes());
        n += part.len();
    }
    if n > sys::PATH_MAX as usize {
        return None;
    }
    core::str::from_utf8(&buf[..n]).ok()
}

fn run() -> i32 {
    let args = env::args().skip(1);
    let froms = args.len().saturating_sub(1);
    let (Some(to), true) = (args.last(), froms > 0) else {
        Line::new().str("usage: mv FROM TO, or mv FROM... DIR").eprint();
        return 1;
    };
    let dir = fs::metadata(to).is_ok_and(|m| m.is_dir());
    if !dir && froms > 1 {
        Line::new().str("mv: ").str(to).str(": not a directory").eprint();
        return 1;
    }
    let mut status = 0;
    let mut buf: PathBuf = [0; sys::PATH_MAX as usize + 1];
    for from in env::args().skip(1).take(froms) {
        let target = match dir {
            false => to,
            true => match into(&mut buf, to, from) {
                Some(target) => target,
                None => {
                    Line::new().str("mv: ").str(from).str(": name too long").eprint();
                    status = 1;
                    continue;
                }
            },
        };
        if let Err(e) = fs::rename(from, target) {
            // What a rename refuses, said as what it would have done.
            let why = match e.kind() {
                ErrorKind::InvalidInput => "cannot move there",
                ErrorKind::IsADirectory => "would replace a directory",
                ErrorKind::AlreadyExists => "would replace what is there",
                ErrorKind::ResourceBusy => "in use",
                _ => e.description(),
            };
            Line::new().str("mv: ").str(from).str(": ").str(why).eprint();
            status = 1;
        }
    }
    status
}
