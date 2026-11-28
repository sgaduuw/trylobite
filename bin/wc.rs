//! wc [FILE]...: count the lines, words and code points of each file, or
//! of standard input when none is named, and say them on standard
//! output, as Unix's wc does: a line per file, ending with its name, and
//! a total when there are two or more. Exit with 0, or with 1 if a file
//! cannot be opened (said on standard error) or output fails. A filter
//! too, for the end of a pipe: ls | wc.
//!
//! Like the other small tools it writes with `Line`, not core::fmt, and
//! walks its arguments rather than collecting them, so that it fits its
//! four pages (trystd's io::Line).
#![no_std]

use trystd::fs::File;
use trystd::prelude::*;

trystd::main!(run);

#[derive(Default, Clone, Copy)]
struct Counts {
    lines: u32,
    words: u32,
    points: u32,
}

/// Count what `from` reads until its end.
fn count<R: Read>(from: &mut R) -> io::Result<Counts> {
    let mut c = Counts::default();
    let mut inside = false; // inside a word
    let mut buf = [0u8; 243];
    loop {
        let n = from.read(&mut buf)?;
        if n == 0 {
            return Ok(c);
        }
        c.points += n as u32;
        for &b in &buf[..n] {
            if b == b'\n' {
                c.lines += 1;
            }
            // A space, or a control character such as a newline or tab,
            // ends a word.
            if b <= b' ' {
                inside = false;
            } else if !inside {
                inside = true;
                c.words += 1;
            }
        }
    }
}

/// Say the counts, and the name unless it is empty.
fn say(c: Counts, name: &str) -> io::Result<()> {
    let mut line = Line::new();
    line.num(c.lines as i64).byte(b' ').num(c.words as i64).byte(b' ').num(c.points as i64);
    if !name.is_empty() {
        line.byte(b' ').str(name);
    }
    line.print()
}

fn run() -> i32 {
    let names = env::args().skip(1);
    let several = names.len() > 1;
    if names.len() == 0 {
        return count(&mut io::stdin()).and_then(|c| say(c, "")).is_err() as i32;
    }
    let mut status = 0;
    let mut total = Counts::default();
    for name in names {
        match File::open(name).and_then(|mut f| count(&mut f)) {
            Ok(c) => {
                total.lines += c.lines;
                total.words += c.words;
                total.points += c.points;
                if say(c, name).is_err() {
                    return 1;
                }
            }
            Err(e) => {
                Line::new().str("wc: ").str(name).str(": ").error(&e).eprint();
                status = 1;
            }
        }
    }
    if several && say(total, "total").is_err() {
        return 1;
    }
    status
}
