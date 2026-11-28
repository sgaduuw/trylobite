//! cp FROM TO, cp FROM... DIR: copy file FROM to TO, made or emptied
//! first, or each FROM into directory DIR under its own last name, as
//! Unix's cp does. Directories are not copied, nor a file onto itself.
//! Exit with 0, or with 1 if anything fails (said on standard error).
#![no_std]

use trystd::fs::{self, File};
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

/// Copy `from` to `to`, saying why not on standard error.
fn copy(from: &str, to: &str) -> bool {
    let what = match fs::metadata(from) {
        Ok(m) => m,
        Err(e) => return failed(from, e.description()),
    };
    if what.is_dir() {
        return failed(from, "is a directory");
    }
    if fs::metadata(to).is_ok_and(|m| m.ino() == what.ino()) {
        return failed(from, "is the same file");
    }
    let mut input = match File::open(from) {
        Ok(f) => f,
        Err(e) => return failed(from, e.description()),
    };
    let mut output = match File::create(to) {
        Ok(f) => f,
        Err(e) => return failed(to, e.description()),
    };
    match io::copy(&mut input, &mut output) {
        Ok(_) => true,
        Err(e) => failed(to, e.description()),
    }
}

fn failed(name: &str, why: &str) -> bool {
    Line::new().str("cp: ").str(name).str(": ").str(why).eprint();
    false
}

fn run() -> i32 {
    let args = env::args().skip(1);
    let froms = args.len().saturating_sub(1);
    let (Some(to), true) = (args.last(), froms > 0) else {
        Line::new().str("usage: cp FROM TO, or cp FROM... DIR").eprint();
        return 1;
    };
    let dir = fs::metadata(to).is_ok_and(|m| m.is_dir());
    if !dir && froms > 1 {
        failed(to, "not a directory");
        return 1;
    }
    let mut status = 0;
    let mut buf: PathBuf = [0; sys::PATH_MAX as usize + 1];
    for from in env::args().skip(1).take(froms) {
        let ok = match dir {
            false => copy(from, to),
            true => match into(&mut buf, to, from) {
                Some(target) => copy(from, target),
                None => failed(from, "name too long"),
            },
        };
        if !ok {
            status = 1;
        }
    }
    status
}
