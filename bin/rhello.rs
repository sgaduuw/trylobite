//! rhello: hello, from Rust. The first program in Rust, translated from
//! rustc's LLVM IR by detrytus ll (docs/rust.md), and printing through
//! the system library, trystd (lib/rust/trystd).
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() {
    println!("hello from Rust on a balanced-ternary machine");
}
