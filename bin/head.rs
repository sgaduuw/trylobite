//! head [-n N] [FILE]...: say the first N lines (10 unless given) of each
//! file, or of standard input when none is named, on standard output, as
//! Unix's head does: with two files or more, each starts with a line
//! "==> NAME <==", and a blank line comes between them. Exit with 0, or
//! with 1 if a file cannot be opened (said on standard error), N is not
//! a number, or output fails. A filter too: ls bin | head -n 3.
#![no_std]

use trystd::fs::File;
use trystd::prelude::*;

trystd::main!(run);

/// Copy what `from` reads to standard output, up to the end of its
/// `lines`th line or its end.
fn copy<R: Read>(from: &mut R, lines: u32) -> io::Result<()> {
    let mut out = io::stdout();
    let mut left = lines;
    let mut buf = [0u8; 243];
    while left > 0 {
        let n = from.read(&mut buf)?;
        if n == 0 {
            break;
        }
        let mut i = 0;
        while i < n && left > 0 {
            if buf[i] == b'\n' {
                left -= 1;
            }
            i += 1;
        }
        out.write_all(&buf[..i])?;
    }
    out.flush()
}

/// A count in decimal digits, at most 9 of them.
fn number(s: &str) -> Option<u32> {
    if s.is_empty() || s.len() > 9 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(s.bytes().fold(0, |n, b| n * 10 + (b - b'0') as u32))
}

fn usage() -> i32 {
    Line::new().str("usage: head [-n N] [FILE]...").eprint();
    1
}

fn run() -> i32 {
    let mut args = env::args().skip(1).peekable();
    let mut lines = 10;
    if args.peek().is_some_and(|a| a.starts_with('-')) {
        if args.next() != Some("-n") {
            return usage();
        }
        lines = match args.next().and_then(number) {
            Some(n) => n,
            None => return usage(),
        };
    }
    if args.len() == 0 {
        return copy(&mut io::stdin(), lines).is_err() as i32;
    }
    let named = args.len() > 1;
    let mut said = false;
    let mut status = 0;
    for name in args {
        let done = File::open(name).and_then(|mut file| {
            if named {
                let mut line = Line::new();
                if said {
                    line.print()?; // a blank line between files
                }
                said = true;
                line.str("==> ").str(name).str(" <==").print()?;
            }
            copy(&mut file, lines)
        });
        if let Err(e) = done {
            Line::new().str("head: ").str(name).str(": ").error(&e).eprint();
            status = 1;
        }
    }
    status
}
