//! What a Rust program on trylobite shares: system calls, standard
//! descriptors and its arguments. A program in bin/ brings it in with
//!
//!     #[path = "../lib/rust/sys.rs"]
//!     mod sys;
//!
//! The calls themselves are assembly, in lib/rust/start.s. `print!`,
//! `println!` and `eprintln!` format as std's do, through core::fmt.

#![allow(dead_code)]

use core::ffi::{CStr, c_char};

unsafe extern "C" {
    fn write(fd: i32, buf: *const u8, n: usize) -> isize;
    fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
    fn exit(code: i32) -> !;
}

pub const STDIN: i32 = 0;
pub const STDOUT: i32 = 1;
pub const STDERR: i32 = 2;

/// Write all of `bytes` to descriptor `fd`: false if that fails.
pub fn put(fd: i32, bytes: &[u8]) -> bool {
    unsafe { write(fd, bytes.as_ptr(), bytes.len()) >= 0 }
}

/// Read into `buf` from descriptor `fd`: how many bytes (0 at the end),
/// or None if reading fails.
pub fn get(fd: i32, buf: &mut [u8]) -> Option<usize> {
    let n = unsafe { read(fd, buf.as_mut_ptr(), buf.len()) };
    if n < 0 { None } else { Some(n as usize) }
}

/// A descriptor to format into: `write!(Out(STDOUT), ...)`.
pub struct Out(pub i32);

impl core::fmt::Write for Out {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        if put(self.0, s.as_bytes()) { Ok(()) } else { Err(core::fmt::Error) }
    }
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => {{
        let _ = core::fmt::Write::write_fmt(&mut $crate::sys::Out($crate::sys::STDOUT), format_args!($($arg)*));
    }};
}

#[macro_export]
macro_rules! println {
    ($($arg:tt)*) => {{
        let _ = core::fmt::Write::write_fmt(&mut $crate::sys::Out($crate::sys::STDOUT), format_args!("{}\n", format_args!($($arg)*)));
    }};
}

#[macro_export]
macro_rules! eprintln {
    ($($arg:tt)*) => {{
        let _ = core::fmt::Write::write_fmt(&mut $crate::sys::Out($crate::sys::STDERR), format_args!("{}\n", format_args!($($arg)*)));
    }};
}

/// End the program with exit code `code`.
pub fn quit(code: i32) -> ! {
    unsafe { exit(code) }
}

/// The program's arguments, as main received them, the command first.
pub fn args(argc: i32, argv: *const *const u8) -> impl Iterator<Item = &'static [u8]> {
    (0..argc as usize).map(move |i| unsafe {
        CStr::from_ptr(*argv.add(i) as *const c_char).to_bytes()
    })
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    // Panics abort before they get here (detrytus docs/rust.md).
    quit(101)
}
