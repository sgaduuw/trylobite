//! The Rust part of the trylobite kernel (docs/kernel.md, "Rust in the
//! kernel"). The assembly kernel calls the functions named `rk_*`; they
//! work on its data in place, through words (word.rs), and call back into
//! it where a routine is still assembly. One module per subsystem, as the
//! assembly has one file per subsystem; a module replaces its file's
//! routines as the port goes on.

#![no_std]

mod boot;
mod console;
mod desc;
mod devices;
mod harts;
mod info;
mod ipc;
mod kdata;
mod mem;
mod mm;
mod names;
mod proc;
mod procinfo;
mod sched;
mod syscall;
mod thread;
mod trytes;
mod wait;
mod word;

/// Every `.equ` of include/layout.s that needs no build's names, each
/// an i64 (lib/rust/trystd/build.rs).
#[allow(dead_code)]
mod layout {
    include!(concat!(env!("OUT_DIR"), "/layout.rs"));
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe extern "C" {
        /// kernel/rt.s: a Rust panic is a kernel panic.
        fn abort() -> !;
    }
    unsafe { abort() }
}
