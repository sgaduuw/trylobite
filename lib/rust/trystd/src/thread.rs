//! Threads, as std's: `thread::spawn` runs a closure beside the rest of
//! the program, in the same memory, and its `JoinHandle` gives back
//! what the closure returned. Each is a thread of the kernel's
//! (docs/kernel.md, Threads), so threads run on different harts at once
//! when the machine has more than one; `sync` has the locks to share
//! data between them.
//!
//! Where trylobite differs from std: a panic in any thread ends the
//! whole program (detrytus aborts on panic), so `join` never reports
//! one; `process::exit` or returning from main ends every thread, as
//! on Unix; and a thread's stack is a block of the heap, `Builder`'s
//! `stack_size` or DEFAULT_STACK trytes, not one that grows.
//!
//! A `JoinHandle` dropped without `join` lets its thread run on alone:
//! the thread's slot and stack go back once it has ended, the next time
//! the program spawns a thread or joins one.

use alloc::boxed::Box;
use alloc::sync::Arc;
use alloc::vec::Vec;
use core::cell::UnsafeCell;
use core::sync::atomic::{AtomicBool, Ordering};

use crate::io;
use crate::sync::Mutex;
use crate::sys;

/// A thread's stack, in trytes, unless `Builder::stack_size` says.
pub const DEFAULT_STACK: usize = 16_384;

/// Trytes a stack needs at least: the thread's own words, and room for
/// a few calls.
const MIN_STACK: usize = 729;

/// Trytes at the bottom of each stack block for the thread's own words
/// (lib/rust/start.s, sys: what a call leaves in a1 to a3), three words
/// and room to align them.
const OWN: usize = 12;

/// What a thread leaves for its join: the closure's value.
struct Packet<T> {
    value: UnsafeCell<Option<T>>,
    done: AtomicBool,
}

// The thread writes it before it ends, the joiner reads it after join
// has seen it end: never both at once.
unsafe impl<T: Send> Sync for Packet<T> {}

/// Threads whose handles were dropped: each one's number and stack,
/// until it has ended.
static LOOSE: Mutex<Vec<(i32, Vec<u8>)>> = Mutex::new(Vec::new());

/// A thread to wait for: `join` gives what its closure returned.
pub struct JoinHandle<T> {
    tid: i32,
    packet: Arc<Packet<T>>,
    stack: Option<Vec<u8>>,
}

impl<T> JoinHandle<T> {
    /// Wait for the thread to end, and take what its closure returned.
    pub fn join(mut self) -> io::Result<T> {
        let r = sys::call(sys::SYS_JOIN, &[self.tid, sys::JOIN_WAIT]);
        sys::check(r)?;
        self.stack = None; // it has gone: its stack is free
        reap();
        // It wrote its value before it ended.
        unsafe { (*self.packet.value.get()).take() }.ok_or(io::Error::from_raw(sys::E_NOCHILD))
    }

    /// Whether the thread has ended (its closure has returned).
    pub fn is_finished(&self) -> bool {
        self.packet.done.load(Ordering::Acquire)
    }

    /// The thread's number, as the kernel's calls (and ps) know it.
    pub fn id(&self) -> i32 {
        self.tid
    }
}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {
        if let Some(stack) = self.stack.take() {
            // Not joined: it runs on alone, and reap frees it later.
            LOOSE.lock().unwrap().push((self.tid, stack));
        }
    }
}

/// Give back the slots and stacks of loose threads that have ended.
fn reap() {
    let mut loose = LOOSE.lock().unwrap();
    loose.retain(|&(tid, _)| sys::call(sys::SYS_JOIN, &[tid, sys::JOIN_POLL]) == sys::E_BUSY);
}

/// A thread's settings before it starts, as std's `Builder`.
pub struct Builder {
    stack: usize,
}

impl Builder {
    pub fn new() -> Builder {
        Builder {
            stack: DEFAULT_STACK,
        }
    }

    /// Its stack, in trytes.
    pub fn stack_size(mut self, trytes: usize) -> Builder {
        self.stack = trytes.max(MIN_STACK);
        self
    }

    /// Start the thread: its handle, or the kernel's error (no free
    /// slot in the process table, or no memory for its stack).
    pub fn spawn<F, T>(self, f: F) -> io::Result<JoinHandle<T>>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        reap();
        crate::sync::threaded(); // from here on, the library locks
        let packet = Arc::new(Packet {
            value: UnsafeCell::new(None),
            done: AtomicBool::new(false),
        });
        let theirs = packet.clone();
        let main: Box<dyn FnOnce() + Send> = Box::new(move || {
            let value = f();
            unsafe { *theirs.value.get() = Some(value) };
            theirs.done.store(true, Ordering::Release);
        });
        let mut stack: Vec<u8> = Vec::new();
        if stack.try_reserve_exact(self.stack).is_err() {
            return Err(io::Error::from_raw(sys::E_NOMEM));
        }
        stack.resize(self.stack, 0);
        let base = stack.as_mut_ptr() as usize;
        // Words are at multiples of 3, each from the tryte below.
        let own = (base + 1).div_ceil(3) * 3;
        let top = (base + self.stack - 1) / 3 * 3;
        let arg = Box::into_raw(Box::new(main));
        let tid = sys::call(
            sys::SYS_THREAD,
            &[start as usize as i32, top as i32, arg as i32, own as i32],
        );
        if tid < 0 {
            drop(unsafe { Box::from_raw(arg) });
            return Err(io::Error::from_raw(tid));
        }
        Ok(JoinHandle {
            tid,
            packet,
            stack: Some(stack),
        })
    }
}

impl Default for Builder {
    fn default() -> Builder {
        Builder::new()
    }
}

/// Where a thread starts (SYS_THREAD's entry): a0 is its closure, boxed
/// twice; it runs it and ends alone.
extern "C" fn start(arg: usize) -> ! {
    let main = unsafe { Box::from_raw(arg as *mut Box<dyn FnOnce() + Send>) };
    main();
    loop {
        sys::call(sys::SYS_TEXIT, &[0]);
    }
}

/// Run `f` in a new thread, as std's `thread::spawn`: its handle. Ends
/// the program (as a panic) if no thread can start.
pub fn spawn<F, T>(f: F) -> JoinHandle<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    match Builder::new().spawn(f) {
        Ok(h) => h,
        Err(e) => {
            crate::eprintln!("thread::spawn: {e}");
            crate::abort()
        }
    }
}

/// Let another thread or process run.
pub fn yield_now() {
    sys::call(sys::SYS_YIELD, &[]);
}

/// The calling thread's number (SYS_GETTID): the process's number in
/// its first thread.
pub fn current_id() -> i32 {
    sys::call(sys::SYS_GETTID, &[])
}

/// The hart running the calling thread just now (SYS_HART), which may
/// change at any time slice: for showing that threads run in parallel.
pub fn hart() -> i32 {
    sys::call(sys::SYS_HART, &[])
}

unsafe extern "C" {
    #[link_name = "sleep_ticks"]
    fn raw_sleep_ticks(ticks: u32);
}

/// Wait at least `ticks` ticks of the time CSR (SYS_SLEEP), this thread
/// alone. std's `sleep` takes a Duration; the machine counts time in
/// ticks, about a million a second while it idles with a live console
/// (detrytus platform.md, Time), and as fast as it runs otherwise.
pub fn sleep_ticks(ticks: u32) {
    // At most 2^31 - 1, which start.s takes as it is.
    unsafe { raw_sleep_ticks(ticks.min(i32::MAX as u32)) }
}
