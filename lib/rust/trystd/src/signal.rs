//! Signals, as POSIX has them (docs/kernel.md, Signals): `signal` sets
//! what a signal does to this process, `kill` sends one, `block` and
//! `unblock` change which ones the calling thread holds off, and
//! `alarm` sends SIGALRM after a time.
//!
//! ```ignore
//! static STOP: AtomicBool = AtomicBool::new(false);
//! fn on_int(_: i32) {
//!     STOP.store(true, Ordering::Relaxed);
//! }
//! signal::signal(signal::SIGINT, signal::Handler::Catch(on_int))?;
//! while !STOP.load(Ordering::Relaxed) { /* work */ }
//! ```
//!
//! A handler runs on the stack of whichever thread does not block the
//! signal, between two instructions of whatever that thread was doing,
//! so keep it to what is safe there: set an atomic, call `process::exit`.
//! Printing or allocating from a handler can wait forever on a lock the
//! interrupted code holds. A system call the signal cut short goes again
//! after the handler, as with SA_RESTART: trystd never shows E_INTR.
//!
//! SIGSTOP, and by default SIGTSTP (Ctrl-Z), SIGTTIN and SIGTTOU, stop
//! the process until SIGCONT; `kill_group` signals a process group, as
//! the shell does a job (`process::set_group`).
//!
//! Where trylobite differs: a fault is
//! not a signal (it ends the process, and its parent's wait says so),
//! and `kill` reaches a whole process, never one of its threads alone.
//! A child started with `process::Command` keeps the signals this
//! process ignores and blocks, and its other signals do their default,
//! as across Unix's fork and exec.

use core::sync::atomic::{AtomicUsize, Ordering};

use crate::io;
use crate::sys;

pub use crate::sys::{
    NSIG, SIGALRM, SIGCHLD, SIGCONT, SIGHUP, SIGINT, SIGKILL, SIGPIPE, SIGQUIT, SIGSTOP,
    SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGUSR1, SIGUSR2,
};

/// What a signal does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handler {
    /// Its default: end the process, stop it (SIGSTOP, SIGTSTP, SIGTTIN,
    /// SIGTTOU), or nothing (SIGCHLD, SIGCONT).
    Default,
    /// Nothing: it is thrown away.
    Ignore,
    /// Run this function with the signal's number.
    Catch(fn(i32)),
}

/// Each signal's handler while it is caught, as a function address; 0
/// for none.
static HANDLERS: [AtomicUsize; NSIG as usize] = [const { AtomicUsize::new(0) }; NSIG as usize];

/// Every signal's name, by number, as `kill -l` lists them.
pub const NAMES: [(i32, &str); 15] = [
    (SIGHUP, "HUP"),
    (SIGINT, "INT"),
    (SIGQUIT, "QUIT"),
    (SIGKILL, "KILL"),
    (SIGUSR1, "USR1"),
    (SIGUSR2, "USR2"),
    (SIGPIPE, "PIPE"),
    (SIGALRM, "ALRM"),
    (SIGTERM, "TERM"),
    (SIGCHLD, "CHLD"),
    (SIGCONT, "CONT"),
    (SIGSTOP, "STOP"),
    (SIGTSTP, "TSTP"),
    (SIGTTIN, "TTIN"),
    (SIGTTOU, "TTOU"),
];

/// The signal a name gives, with or without "SIG", in any case: "INT",
/// "sigterm".
pub fn by_name(name: &str) -> Option<i32> {
    let n = name.as_bytes();
    let n = if n.len() > 3 && n[..3].eq_ignore_ascii_case(b"SIG") { &n[3..] } else { n };
    NAMES
        .iter()
        .find(|(_, s)| s.as_bytes().eq_ignore_ascii_case(n))
        .map(|&(sig, _)| sig)
}

/// The name of signal `sig`, without "SIG", if it has one.
pub fn name(sig: i32) -> Option<&'static str> {
    NAMES.iter().find(|&&(s, _)| s == sig).map(|&(_, n)| n)
}

/// Make `sig` do what `handler` says from now on: the handler it had.
/// SIGKILL and SIGSTOP can only have their default.
pub fn signal(sig: i32, handler: Handler) -> io::Result<Handler> {
    if !(1..NSIG).contains(&sig) {
        return Err(io::Error::from_raw(sys::E_INVAL));
    }
    let slot = &HANDLERS[sig as usize];
    let (action, f) = match handler {
        Handler::Default => (sys::SIG_DFL, 0),
        Handler::Ignore => (sys::SIG_IGN, 0),
        Handler::Catch(f) => (sys::SIG_CATCH, f as usize),
    };
    // In place before the kernel can run it.
    let old_f = if f != 0 { slot.swap(f, Ordering::SeqCst) } else { slot.load(Ordering::SeqCst) };
    let was = sys::call(sys::SYS_SIGACTION, &[sig, action, entry as usize as i32]);
    if was < 0 {
        slot.store(old_f, Ordering::SeqCst);
        return Err(io::Error::from_raw(was));
    }
    if f == 0 {
        slot.store(0, Ordering::SeqCst);
    }
    Ok(match was {
        sys::SIG_IGN => Handler::Ignore,
        sys::SIG_CATCH if old_f != 0 => {
            Handler::Catch(unsafe { core::mem::transmute::<usize, fn(i32)>(old_f) })
        }
        _ => Handler::Default,
    })
}

/// Where every caught signal starts (SYS_SIGACTION's entry): a0 is the
/// signal and a1 the frame the kernel pushed, below the interrupted sp.
/// It runs the handler and goes back through sigreturn.
extern "C" fn entry(sig: i32, frame: usize) -> ! {
    let f = HANDLERS.get(sig as usize).map_or(0, |s| s.load(Ordering::SeqCst));
    if f != 0 {
        let f = unsafe { core::mem::transmute::<usize, fn(i32)>(f) };
        f(sig);
    }
    sys::call(sys::SYS_SIGRETURN, &[frame as i32]);
    crate::sys::exit_now(sys::E_FAULT) // a frame it cannot go back through
}

/// Send signal `sig` to process `pid`, any but init (kill(pid,
/// KILL_ANY, sig)); signal 0 only checks it is there. Ok(true) if the
/// process will end, Ok(false) if it goes on (or stops).
pub fn kill(pid: i32, sig: i32) -> io::Result<bool> {
    let r = sys::check(sys::call(sys::SYS_KILL, &[pid, sys::KILL_ANY, sig]))?;
    Ok(r == 0)
}

/// What signalling a group did (`kill_group`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sent {
    /// Each process of it will end.
    Ended,
    /// One goes on: it caught, ignored or blocked the signal.
    Caught,
    /// One stopped.
    Stopped,
}

/// Send signal `sig` to each process of group `pgrp` that this process
/// started, or that those started (killpg(pgrp, FOR_SELF, sig)): how
/// it went, or E_NOPROC when there is no such process.
pub fn kill_group(pgrp: u32, sig: i32) -> io::Result<Sent> {
    let r = sys::check(sys::call(sys::SYS_KILLPG, &[pgrp as i32, sys::FOR_SELF, sig]))?;
    Ok(match r {
        sys::KILL_STOPPED => Sent::Stopped,
        sys::KILL_CAUGHT => Sent::Caught,
        _ => Sent::Ended,
    })
}

/// Send signal `sig` to this process.
pub fn raise(sig: i32) -> io::Result<()> {
    let me = sys::call(sys::SYS_GETPID, &[]);
    kill(me, sig).map(|_| ())
}

/// A set of signals.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SigSet(i32);

impl SigSet {
    /// No signals.
    pub const fn empty() -> SigSet {
        SigSet(0)
    }

    /// Every signal (the kernel leaves SIGKILL out of a mask).
    pub const fn all() -> SigSet {
        SigSet(((1i64 << NSIG) - 2) as i32)
    }

    /// The set of `sigs`.
    pub fn of(sigs: &[i32]) -> SigSet {
        sigs.iter().fold(SigSet::empty(), |s, &sig| s.with(sig))
    }

    /// This set and `sig`.
    pub const fn with(self, sig: i32) -> SigSet {
        SigSet(self.0 | 1 << sig)
    }

    /// This set without `sig`.
    pub const fn without(self, sig: i32) -> SigSet {
        SigSet(self.0 & !(1 << sig))
    }

    /// Whether it holds `sig`.
    pub const fn contains(self, sig: i32) -> bool {
        self.0 & 1 << sig != 0
    }
}

fn mask(how: i32, set: SigSet) -> io::Result<SigSet> {
    sys::check(sys::call(sys::SYS_SIGMASK, &[how, set.0])).map(SigSet)
}

/// Hold off the signals of `set` in the calling thread, as well as
/// those it holds off already: they wait until it lets them in, or
/// another thread takes them. The set it had.
pub fn block(set: SigSet) -> io::Result<SigSet> {
    mask(sys::SIG_BLOCK, set)
}

/// Let the signals of `set` in again; one waiting is taken before this
/// returns. The set it had.
pub fn unblock(set: SigSet) -> io::Result<SigSet> {
    mask(sys::SIG_UNBLOCK, set)
}

/// Make the calling thread's blocked set `set`: the set it had.
pub fn set_mask(set: SigSet) -> io::Result<SigSet> {
    mask(sys::SIG_SETMASK, set)
}

/// The calling thread's blocked set.
pub fn blocked() -> SigSet {
    mask(sys::SIG_BLOCK, SigSet::empty()).unwrap_or_default()
}

/// Send this process SIGALRM in `ticks` ticks of the time CSR
/// (`time::Duration`'s clock); a later alarm replaces this one.
pub fn alarm(ticks: u32) {
    unsafe extern "C" {
        /// lib/rust/start.s: SYS_ALARM at the time CSR plus n, a sum
        /// that outgrows an i32.
        fn alarm_ticks(n: u32, how: i32);
    }
    unsafe { alarm_ticks(ticks, sys::ALARM_SIGNAL) }
}

/// Cancel the alarm, if one is set.
pub fn cancel_alarm() {
    sys::call(sys::SYS_ALARM, &[sys::NO_ALARM, sys::ALARM_SIGNAL]);
}
