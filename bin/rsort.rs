//! rsort [-r] [-u]: standard input's lines, sorted (in reverse with -r,
//! each once with -u), to standard output, as Unix's sort. The lines
//! are read into a growing Vec<u8> and sorted as a Vec<String> with
//! Rust's stable sort: memory from the heap (trystd's, lib/rust/trystd).
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let (mut reverse, mut unique) = (false, false);
    for arg in env::args().skip(1) {
        match arg {
            "-r" => reverse = true,
            "-u" => unique = true,
            _ => {
                eprintln!("usage: rsort [-r] [-u]");
                return 1;
            }
        }
    }
    let mut input: Vec<u8> = Vec::new();
    if io::stdin().read_to_end(&mut input).is_err() {
        eprintln!("rsort: cannot read");
        return 1;
    }
    let mut lines: Vec<String> = input
        .split(|&c| c == b'\n')
        .map(|l| String::from_utf8_lossy(l).into_owned())
        .collect();
    if input.last() == Some(&b'\n') {
        lines.pop(); // the empty string after the last newline
    }
    lines.sort();
    if reverse {
        lines.reverse();
    }
    if unique {
        lines.dedup();
    }
    let mut out = io::stdout();
    for line in &lines {
        if writeln!(out, "{line}").is_err() {
            eprintln!("rsort: cannot write");
            return 1;
        }
    }
    0
}
