//! spin: loop forever without a system call, a runaway to try Ctrl-C
//! on. Only the timer takes the hart away from it.
#![no_std]

trystd::main!(run);

fn run() -> i32 {
    #[allow(clippy::empty_loop)]
    loop {}
}
