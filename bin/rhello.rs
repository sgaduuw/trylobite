//! rhello: hello, from Rust. The first program in Rust, translated from
//! rustc's LLVM IR by detrytus ll (docs/rust.md).
#![no_std]

#[path = "../lib/rust/sys.rs"]
mod sys;

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: i32, _argv: *const *const u8) -> i32 {
    sys::put(sys::STDOUT, b"hello from Rust on a balanced-ternary machine\n");
    0
}
