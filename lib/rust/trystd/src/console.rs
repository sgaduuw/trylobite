//! The console server (user/consd.s, docs/kernel.md, The console): a
//! descriptor for it, and its foreground, the process Ctrl-C ends. A
//! program normally has the console already as its standard input,
//! output and error, inherited; these are for the one that hands it out
//! (the shell) and for one that wants Ctrl-C as a key (vi).

use crate::fs::OwnedFd;
use crate::io;
use crate::sys::{self, CONSOLE};

/// A new descriptor for the console (CN_OPEN).
pub fn open() -> io::Result<OwnedFd> {
    CONSOLE.call(sys::CN_OPEN, &[]).map(OwnedFd::from_raw)
}

/// Make process `pid` the foreground, which Ctrl-C ends, or nobody with
/// None, when Ctrl-C reaches whoever reads the console as a key.
pub fn set_foreground(pid: Option<u32>) -> io::Result<()> {
    let pid = pid.map_or(sys::NO_FOREGROUND, |p| p as i32);
    CONSOLE.call(sys::CN_FOREGROUND, &[pid]).map(|_| ())
}
