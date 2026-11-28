//! ls [-l] [-a] [PATH...]: each entry of each directory PATH (or of the
//! current directory), and each file PATH itself, as Unix's ls lists
//! them, in name order (the file server's). Names that start with a dot
//! are left out unless -a. Without -l, a file's size and name and a
//! directory's name and a slash, as the shell's built-in ls; with -l,
//! Unix's long form: type and permissions, links, owner, group, size,
//! when it was last written (UTC, as ls --time-style=long-iso) and name. Exit with 0, or with 1 if a
//! PATH cannot be listed (said on standard error).
#![no_std]

use trystd::fs::{self, Metadata};
use trystd::prelude::*;
use trystd::time::Utc;

trystd::main!(run);

struct Opts {
    long: bool,
    all: bool,
}

fn run() -> i32 {
    let mut opts = Opts { long: false, all: false };
    let mut paths = 0;
    for arg in env::args().skip(1) {
        match arg.strip_prefix('-') {
            Some(flags) if !flags.is_empty() => {
                for f in flags.bytes() {
                    match f {
                        b'l' => opts.long = true,
                        b'a' => opts.all = true,
                        _ => {
                            Line::new().str("usage: ls [-l] [-a] [PATH...]").eprint();
                            return 2;
                        }
                    }
                }
            }
            _ => paths += 1,
        }
    }
    let mut status = 0;
    if paths == 0 {
        status |= list(".", &opts, false);
    }
    for arg in env::args().skip(1) {
        if !arg.starts_with('-') || arg == "-" {
            status |= list(arg, &opts, paths > 1);
        }
    }
    status
}

/// List `path`: a directory's entries, or the file. 0, or 1 on failure.
fn list(path: &str, opts: &Opts, heading: bool) -> i32 {
    let m = match fs::metadata(path) {
        Ok(m) => m,
        Err(e) => return fail(path, &e),
    };
    if !m.is_dir() {
        entry(path, &m, opts);
        return 0;
    }
    if heading {
        Line::new().str(path).str(":").print().ok();
    }
    let dir = match fs::read_dir(path) {
        Ok(d) => d,
        Err(e) => return fail(path, &e),
    };
    if opts.all {
        for dot in [".", ".."] {
            let mut p = String::from(path);
            p.push('/');
            p.push_str(dot);
            if let Ok(m) = fs::metadata(&p) {
                entry(dot, &m, opts);
            }
        }
    }
    let mut status = 0;
    for e in dir {
        match e.and_then(|e| e.metadata().map(|m| (e, m))) {
            Ok((e, m)) => {
                if opts.all || !e.file_name().starts_with('.') {
                    entry(e.file_name(), &m, opts);
                }
            }
            Err(err) => status = fail(path, &err),
        }
    }
    status
}

fn entry(name: &str, m: &Metadata, opts: &Opts) {
    let mut line = Line::new();
    if !opts.long {
        if m.is_dir() {
            line.str(name).str("/");
        } else {
            line.num(m.len() as i64).str(" ").str(name);
        }
        line.print().ok();
        return;
    }
    line.byte(if m.is_dir() { b'd' } else { b'-' });
    for shift in [6, 3, 0] {
        let bits = m.mode() >> shift;
        for (bit, c) in [(4, b'r'), (2, b'w'), (1, b'x')] {
            line.byte(if bits & bit != 0 { c } else { b'-' });
        }
    }
    line.num_right(m.nlink() as i64, 3).str(" ");
    line.num_right(m.uid() as i64, 4).str(" ");
    line.num_right(m.gid() as i64, 4);
    line.num_right(m.len() as i64, 8).str(" ");
    if let Ok(t) = m.modified() {
        let t = Utc::from_system_time(t);
        line.num(t.year).str("-");
        two(&mut line, t.month).str("-");
        two(&mut line, t.day).str(" ");
        two(&mut line, t.hour).str(":");
        two(&mut line, t.minute).str(" ");
    }
    line.str(name);
    if m.is_dir() {
        line.str("/");
    }
    line.print().ok();
}

fn two(line: &mut Line, n: u32) -> &mut Line {
    if n < 10 {
        line.str("0");
    }
    line.num(n as i64)
}

fn fail(path: &str, e: &io::Error) -> i32 {
    Line::new().str("ls: ").str(path).str(": ").error(e).eprint();
    1
}
