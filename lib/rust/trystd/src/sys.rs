//! The kernel underneath: its numbers, its calls and its servers.
//!
//! Every number is include/layout.s's, written out as Rust by build.rs,
//! so `sys::SYS_WRITE` and `sys::E_NOENT` are the kernel's own. The
//! calls are assembly, in lib/rust/start.s: `sys` takes each argument as
//! a signed i32, so -1 arrives as -1, and `sysu` takes them unsigned,
//! for an IPv4 address of 2^31 or more. Results that are negative are
//! failures, as in the kernel; the rest of the library turns them into
//! `io::Error`s.

#![allow(dead_code, clippy::all)]

include!(concat!(env!("OUT_DIR"), "/layout.rs"));

unsafe extern "C" {
    #[link_name = "sys"]
    fn raw_sys(n: i32, a: i32, b: i32, c: i32, d: i32, e: i32) -> i32;
    #[link_name = "sysu"]
    fn raw_sysu(n: i32, a: u32, b: u32, c: u32, d: u32, e: u32) -> i32;
    #[link_name = "sys_more"]
    fn raw_more(k: i32) -> i32;
    #[link_name = "word_at"]
    fn raw_word_at(address: usize) -> i32;
    #[link_name = "word_split"]
    fn raw_word_split(address: usize) -> u32;
    #[link_name = "ticks"]
    fn raw_ticks() -> u32;
    #[link_name = "sleep_until"]
    fn raw_sleep_until(low: u32, high: i32);
    #[link_name = "argc"]
    fn raw_argc() -> i32;
    #[link_name = "argv"]
    fn raw_argv() -> *const *const u8;
    fn exit(code: i32) -> !;
}

/// System call `n` with up to five arguments, each taken signed: the
/// call's a0.
pub fn call(n: i32, args: &[i32]) -> i32 {
    let a = |k: usize| args.get(k).copied().unwrap_or(0);
    unsafe { raw_sys(n, a(0), a(1), a(2), a(3), a(4)) }
}

/// The same with the arguments taken unsigned, so that an address of
/// 2^31 or more stays positive.
pub fn callu(n: i32, args: &[u32]) -> i32 {
    let a = |k: usize| args.get(k).copied().unwrap_or(0);
    unsafe { raw_sysu(n, a(0), a(1), a(2), a(3), a(4)) }
}

/// What the last call left in a1 (`k` = 0), a2 or a3: the further
/// results of a call that has several, such as lookup's version.
pub fn more(k: i32) -> i32 {
    unsafe { raw_more(k) }
}

/// The word at an aligned address in this process's memory.
pub fn word_at(address: usize) -> i32 {
    unsafe { raw_word_at(address) }
}

/// The word at an aligned address whole, past what an i32 holds: a
/// count of ticks, Unix seconds.
pub fn word_at_i64(address: usize) -> i64 {
    let low = unsafe { raw_word_split(address) };
    ((more(0) as i64) << 32) | low as i64
}

/// The time CSR: ticks since boot, the clock for intervals.
pub fn ticks() -> i64 {
    let low = unsafe { raw_ticks() };
    ((more(0) as i64) << 32) | low as i64
}

/// Wait until the time CSR reaches `until` (SYS_SLEEP, absolute).
pub fn sleep_until(until: i64) {
    unsafe { raw_sleep_until(until as u32, (until >> 32) as i32) }
}

/// main's arguments as the start code laid them out.
pub(crate) fn argc() -> i32 {
    unsafe { raw_argc() }
}

pub(crate) fn argv() -> *const *const u8 {
    unsafe { raw_argv() }
}

/// End the process with exit code `code`, as it is.
pub(crate) fn exit_now(code: i32) -> ! {
    unsafe { exit(code) }
}

/// A call's result as a `Result`: the error for a negative one.
pub fn check(r: i32) -> crate::io::Result<i32> {
    if r < 0 {
        Err(crate::io::Error::from_raw(r))
    } else {
        Ok(r)
    }
}

/// A call to server `pid` (SYS_CALL): operation `op`, then up to three
/// more arguments, signed.
pub fn server_call(pid: i32, op: i32, args: &[i32]) -> crate::io::Result<i32> {
    let a = |k: usize| args.get(k).copied().unwrap_or(0);
    check(call(SYS_CALL, &[pid, op, a(0), a(1), a(2)]))
}

/// A server, looked up by name once and then remembered: its process
/// number, or why there is none.
pub struct Server {
    name: &'static [u8],
    protocol: i32,
    pid: core::cell::Cell<i32>,
}

// A program is one process with one thread of control.
unsafe impl Sync for Server {}

/// A process number that no lookup gives: not looked up yet.
const UNKNOWN: i32 = i32::MIN;

impl Server {
    /// `name` ends with 0.
    pub const fn new(name: &'static [u8], protocol: i32) -> Server {
        Server {
            name,
            protocol,
            pid: core::cell::Cell::new(UNKNOWN),
        }
    }

    /// The server's process number, E_NOPROC when there is none or it
    /// speaks another protocol than ours.
    pub fn pid(&self) -> crate::io::Result<i32> {
        if self.pid.get() == UNKNOWN {
            let pid = call(SYS_LOOKUP, &[self.name.as_ptr() as i32, LOOKUP_NOW]);
            let ok = pid >= 0 && more(0) == self.protocol;
            self.pid.set(if ok { pid } else { E_NOPROC });
        }
        check(self.pid.get())
    }

    /// A call to it: operation `op` and up to three arguments, signed.
    pub fn call(&self, op: i32, args: &[i32]) -> crate::io::Result<i32> {
        server_call(self.pid()?, op, args)
    }

    /// The same with unsigned arguments (an IPv4 address).
    pub fn callu(&self, op: i32, args: &[u32]) -> crate::io::Result<i32> {
        let pid = self.pid()?;
        let a = |k: usize| args.get(k).copied().unwrap_or(0);
        check(callu(SYS_CALL, &[pid as u32, op as u32, a(0), a(1), a(2)]))
    }
}

pub static FS: Server = Server::new(b"fs\0", FS_PROTOCOL);
pub static IP: Server = Server::new(b"ip\0", IP_PROTOCOL);
pub static PIPE: Server = Server::new(b"pipe\0", PIPE_PROTOCOL);

/// A path as the file server takes it: its bytes, then 0, in a buffer
/// on the stack. E_NAMETOOLONG past PATH_MAX, E_INVAL for a 0 inside.
pub struct CPath {
    buf: [u8; PATH_MAX as usize + 1],
}

impl CPath {
    pub fn new(path: &[u8]) -> crate::io::Result<CPath> {
        if path.len() > PATH_MAX as usize {
            return Err(crate::io::Error::from_raw(E_NAMETOOLONG));
        }
        if path.contains(&0) {
            return Err(crate::io::Error::from_raw(E_INVAL));
        }
        let mut buf = [0u8; PATH_MAX as usize + 1];
        buf[..path.len()].copy_from_slice(path);
        Ok(CPath { buf })
    }

    pub fn ptr(&self) -> i32 {
        self.buf.as_ptr() as i32
    }
}

/// Room for `N` words, aligned, in a buffer of trytes: where a call
/// leaves words (stat, statfs) for `word` to read.
pub struct Words<const T: usize> {
    buf: [u8; T],
}

impl<const T: usize> Words<T> {
    pub fn new() -> Self {
        Words { buf: [0; T] }
    }

    /// The first word's address: a multiple of 3, past the buffer's
    /// first tryte, so that the word's lower tryte is in the buffer too.
    pub fn ptr(&self) -> usize {
        let a = self.buf.as_ptr() as usize + 1;
        a + (3 - a % 3) % 3
    }

    /// The word at offset `at` (in trytes, a multiple of 3).
    pub fn word(&self, at: i32) -> i32 {
        word_at(self.ptr() + at as usize)
    }

    /// The same, whole, for a word past what an i32 holds.
    pub fn word_i64(&self, at: i32) -> i64 {
        word_at_i64(self.ptr() + at as usize)
    }

    /// The tryte at offset `at`, a code point of a string the call left.
    pub fn tryte(&self, at: i32) -> u8 {
        self.buf[self.ptr() - self.buf.as_ptr() as usize + at as usize]
    }
}
