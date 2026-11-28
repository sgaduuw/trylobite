//! The program's arguments and its current directory, as std::env has
//! them.

use alloc::string::String;
use core::ffi::{CStr, c_char};

use crate::io;
use crate::sys::{self, CPath, FS};

/// The program's arguments, the command as typed first. Unlike std's,
/// each is a `&'static str`, with no copy made; one that is not UTF-8
/// ends the program as a panic does (`args_bytes` takes any).
pub fn args() -> Args {
    Args {
        bytes: args_bytes(),
    }
}

/// The arguments as bytes, whatever they hold.
pub fn args_bytes() -> ArgsBytes {
    ArgsBytes {
        next: 0,
        count: sys::argc() as usize,
        argv: sys::argv(),
    }
}

pub struct ArgsBytes {
    next: usize,
    count: usize,
    argv: *const *const u8,
}

impl Iterator for ArgsBytes {
    type Item = &'static [u8];

    fn next(&mut self) -> Option<&'static [u8]> {
        if self.next == self.count {
            return None;
        }
        let arg = unsafe { CStr::from_ptr(*self.argv.add(self.next) as *const c_char) };
        self.next += 1;
        Some(arg.to_bytes())
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let left = self.count - self.next;
        (left, Some(left))
    }
}

impl ExactSizeIterator for ArgsBytes {}

pub struct Args {
    bytes: ArgsBytes,
}

impl Iterator for Args {
    type Item = &'static str;

    fn next(&mut self) -> Option<&'static str> {
        let arg = self.bytes.next()?;
        match core::str::from_utf8(arg) {
            Ok(s) => Some(s),
            Err(_) => crate::abort(),
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.bytes.size_hint()
    }
}

impl ExactSizeIterator for Args {}

/// The current directory's path, from the root (FS_GETCWD).
pub fn current_dir() -> io::Result<String> {
    let mut buf = [0u8; sys::PATH_MAX as usize + 1];
    Ok(String::from_utf8_lossy(current_dir_in(&mut buf)?).into_owned())
}

/// The same into `buf`, without the heap: the path's bytes.
pub fn current_dir_in(buf: &mut [u8]) -> io::Result<&[u8]> {
    let n = FS.call(sys::FS_GETCWD, &[buf.as_mut_ptr() as i32, buf.len() as i32])?;
    Ok(&buf[..n as usize])
}

/// Make `path` the current directory (FS_CHDIR), for this process and
/// the children it starts from now on.
pub fn set_current_dir<P: AsRef<[u8]>>(path: P) -> io::Result<()> {
    let path = CPath::new(path.as_ref())?;
    FS.call(sys::FS_CHDIR, &[path.ptr()]).map(|_| ())
}
