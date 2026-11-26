//! rsort [-r] [-u]: standard input's lines, sorted (in reverse with -r,
//! each once with -u), to standard output, as Unix's sort. The lines
//! are read into a growing Vec<u8> and sorted as a Vec<String> with
//! Rust's stable sort: memory from the heap (lib/rust/heap.rs).
#![no_std]

extern crate alloc;

#[path = "../lib/rust/heap.rs"]
mod heap;
#[path = "../lib/rust/sys.rs"]
mod sys;

use alloc::string::String;
use alloc::vec::Vec;

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: i32, argv: *const *const u8) -> i32 {
    let (mut reverse, mut unique) = (false, false);
    for arg in sys::args(argc, argv).skip(1) {
        match arg {
            b"-r" => reverse = true,
            b"-u" => unique = true,
            _ => {
                eprintln!("usage: rsort [-r] [-u]");
                return 1;
            }
        }
    }
    let mut input: Vec<u8> = Vec::new();
    let mut buf = [0u8; 243];
    loop {
        match sys::get(sys::STDIN, &mut buf) {
            Some(0) => break,
            Some(n) => input.extend_from_slice(&buf[..n]),
            None => {
                eprintln!("rsort: cannot read");
                return 1;
            }
        }
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
    for line in &lines {
        if !sys::put(sys::STDOUT, line.as_bytes()) || !sys::put(sys::STDOUT, b"\n") {
            eprintln!("rsort: cannot write");
            return 1;
        }
    }
    0
}
