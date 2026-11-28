//! trystd: the system library for Rust programs on trylobite.
//!
//! What std is to a Rust program on Unix, this is on trylobite: files
//! and directories (`fs`), standard I/O and the I/O traits (`io`), the
//! program's arguments and current directory (`env`), child processes
//! (`process`), sockets (`net`), the time of day (`time`) and threads
//! (`thread`, `sync`), and the kernel's reports on the machine and
//! its processes (`os`), each a thin, safe layer over the kernel's calls
//! and its servers (docs/kernel.md), with `alloc`'s
//! `Vec`, `String` and `Box` over the heap (`heap`). It is written in
//! Rust alone: no C library sits under it. The names follow std's, so
//! that a program reads as one for std does; where trylobite differs,
//! the item's documentation says how.
//!
//! A program in bin/ is a `no_std` crate that tools/fs.py builds with
//! this one as a dependency:
//!
//! ```ignore
//! #![no_std]
//! use trystd::prelude::*;
//!
//! trystd::main!(run);
//!
//! fn run() -> io::Result<()> {
//!     for arg in env::args().skip(1) {
//!         println!("{arg}");
//!     }
//!     Ok(())
//! }
//! ```
//!
//! `main!` makes the `main` that lib/rust/start.s calls. The function
//! it names may return nothing, an exit code, or a `Result`, whose
//! error ends the program with exit code 1 after "PROGRAM: ERROR" on
//! standard error. Standard output goes out before the program ends.
//!
//! Errors are the kernel's: an `io::Error` holds its E_ number, and the
//! numbers themselves are in `sys`, read from include/layout.s when the
//! library is built.

#![no_std]

extern crate alloc;

mod heap;

pub mod env;
pub mod fs;
pub mod io;
pub mod net;
pub mod os;
pub mod process;
pub mod sync;
pub mod sys;
pub mod thread;
pub mod time;

pub use alloc::{boxed, format, string, vec};

/// What most programs use, brought in with `use trystd::prelude::*`.
pub mod prelude {
    pub use crate::io::{self, BufRead, Line, Read, Seek, Write};
    pub use crate::{env, fs, net, process, sync, thread, time};
    pub use crate::{eprint, eprintln, print, println};
    pub use alloc::borrow::ToOwned;
    pub use alloc::boxed::Box;
    pub use alloc::format;
    pub use alloc::string::{String, ToString};
    pub use alloc::vec;
    pub use alloc::vec::Vec;
}

/// Print to standard output, as std's `print!`.
#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => { $crate::io::_print(format_args!($($arg)*)) };
}

/// Print a line to standard output, as std's `println!`.
#[macro_export]
macro_rules! println {
    () => { $crate::io::_print(format_args!("\n")) };
    ($($arg:tt)*) => { $crate::io::_print(format_args!("{}\n", format_args!($($arg)*))) };
}

/// Print to standard error, as std's `eprint!`.
#[macro_export]
macro_rules! eprint {
    ($($arg:tt)*) => { $crate::io::_eprint(format_args!($($arg)*)) };
}

/// Print a line to standard error, as std's `eprintln!`.
#[macro_export]
macro_rules! eprintln {
    () => { $crate::io::_eprint(format_args!("\n")) };
    ($($arg:tt)*) => { $crate::io::_eprint(format_args!("{}\n", format_args!($($arg)*))) };
}

/// Make the program's `main` from a function that takes nothing and
/// returns a `process::Termination`: `trystd::main!(run);`.
#[macro_export]
macro_rules! main {
    ($run:path) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn main() -> i32 {
            $crate::_finish($crate::process::Termination::report($run()))
        }
    };
}

#[doc(hidden)]
pub fn _finish(code: i32) -> i32 {
    let _ = io::Write::flush(&mut io::stdout());
    code
}

unsafe extern "C" {
    #[link_name = "abort"]
    fn raw_abort() -> !;
}

/// End at once with a panic's exit code, as a panic does.
pub(crate) fn abort() -> ! {
    unsafe { raw_abort() }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    // Panics abort before they get here (detrytus docs/rust.md).
    abort()
}
