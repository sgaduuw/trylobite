//! recho: echo in Rust. Say the arguments after the command on standard
//! output, a space between each and a newline after; exit with 0, or
//! with 1 if output fails.
#![no_std]

#[path = "../lib/rust/sys.rs"]
mod sys;

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: i32, argv: *const *const u8) -> i32 {
    let mut ok = true;
    for (i, arg) in sys::args(argc, argv).enumerate().skip(1) {
        if i > 1 {
            ok &= sys::put(sys::STDOUT, b" ");
        }
        ok &= sys::put(sys::STDOUT, arg);
    }
    ok &= sys::put(sys::STDOUT, b"\n");
    if ok { 0 } else { 1 }
}
