//! The program's arguments, its environment and its current directory,
//! as std::env has them.
//!
//! The environment is a block of NAME=value strings, each ended by a 0,
//! and an empty string after the last (include/layout.s, V_ENV). A
//! program starts with its parent's at V_ENV; `set_var` and `remove_var`
//! build a new block on the heap and make it the one the kernel copies
//! into every program this one starts from then on (SYS_ENVIRON).

use alloc::string::String;
use alloc::vec::Vec;
use core::ffi::{CStr, c_char};

use crate::io;
use crate::sync::LibLock;
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

/// The environment block this program made, once it has made one; until
/// then it is the one it started with, at V_ENV.
static mut BLOCK: Option<Vec<u8>> = None;
static ENV_LOCK: LibLock = LibLock::new();

/// Call `f` with the environment block, its final 0 left out, under the
/// library's lock.
fn with_block<T>(f: impl FnOnce(&[u8]) -> T) -> T {
    ENV_LOCK.lock();
    let block = unsafe { &*core::ptr::addr_of!(BLOCK) };
    let r = match block {
        Some(b) => f(&b[..b.len() - 1]),
        None => {
            let start = sys::V_ENV as usize as *const u8;
            let mut n = 0;
            // Strings until the empty one, within ENV_MAX.
            unsafe {
                while n < sys::ENV_MAX as usize - 1 && *start.add(n) != 0 {
                    while *start.add(n) != 0 {
                        n += 1;
                    }
                    n += 1;
                }
                f(core::slice::from_raw_parts(start, n))
            }
        }
    };
    ENV_LOCK.unlock();
    r
}

/// Each NAME=value string of a block, split at its first =; one with no
/// = is a name with an empty value.
fn entries(block: &[u8]) -> impl Iterator<Item = (&[u8], &[u8])> {
    block.split(|&c| c == 0).filter(|e| !e.is_empty()).map(|e| {
        match e.iter().position(|&c| c == b'=') {
            Some(k) => (&e[..k], &e[k + 1..]),
            None => (e, &e[e.len()..]),
        }
    })
}

/// Why `var` found no value.
#[derive(Debug, PartialEq, Eq)]
pub enum VarError {
    NotPresent,
    NotUnicode(Vec<u8>),
}

/// The value of environment variable `key`, as std's.
pub fn var<K: AsRef<[u8]>>(key: K) -> Result<String, VarError> {
    match var_bytes(key) {
        None => Err(VarError::NotPresent),
        Some(v) => String::from_utf8(v).map_err(|e| VarError::NotUnicode(e.into_bytes())),
    }
}

/// The value of `key` as bytes, whatever they hold, or None if it is not
/// set.
pub fn var_bytes<K: AsRef<[u8]>>(key: K) -> Option<Vec<u8>> {
    let key = key.as_ref();
    with_block(|b| entries(b).find(|&(n, _)| n == key).map(|(_, v)| v.to_vec()))
}

/// Every variable of the environment, name and value, in its order.
pub fn vars_bytes() -> Vec<(Vec<u8>, Vec<u8>)> {
    with_block(|b| entries(b).map(|(n, v)| (n.to_vec(), v.to_vec())).collect())
}

/// Every variable whose name and value are UTF-8, as std's `vars`.
pub fn vars() -> impl Iterator<Item = (String, String)> {
    vars_bytes().into_iter().filter_map(|(n, v)| Some((String::from_utf8(n).ok()?, String::from_utf8(v).ok()?)))
}

/// Make `key` hold `value` in the environment of the programs this one
/// starts from now on (and of `var`), in place if it is set, else at the
/// end. Unlike std's it can fail: E_INVAL for a name that is empty or
/// holds = or a 0, or a value holding a 0, and E_2BIG when the block
/// would pass ENV_MAX; the environment is then as it was.
pub fn set_var<K: AsRef<[u8]>, V: AsRef<[u8]>>(key: K, value: V) -> io::Result<()> {
    let (key, value) = (key.as_ref(), value.as_ref());
    if key.is_empty() || key.contains(&b'=') || key.contains(&0) || value.contains(&0) {
        return Err(io::Error::from_raw(sys::E_INVAL));
    }
    replace(key, Some(value))
}

/// Take `key` out of the environment, if it is there.
pub fn remove_var<K: AsRef<[u8]>>(key: K) -> io::Result<()> {
    replace(key.as_ref(), None)
}

/// A new block with `key` set to `value`, or gone with None, made the
/// program's environment.
fn replace(key: &[u8], value: Option<&[u8]>) -> io::Result<()> {
    let mut new = Vec::new();
    let mut done = false;
    with_block(|b| {
        for (n, v) in entries(b) {
            let v = if n == key {
                if done {
                    continue; // a name twice: keep the first
                }
                done = true;
                match value {
                    Some(value) => value,
                    None => continue,
                }
            } else {
                v
            };
            push(&mut new, n, v);
        }
    });
    if let (false, Some(value)) = (done, value) {
        push(&mut new, key, value);
    }
    new.push(0);
    if new.len() > sys::ENV_MAX as usize {
        return Err(io::Error::from_raw(sys::E_2BIG));
    }
    ENV_LOCK.lock();
    let r = sys::check(sys::call(sys::SYS_ENVIRON, &[new.as_ptr() as i32]));
    if r.is_ok() {
        // The old block goes only now that the kernel no longer names it.
        unsafe { *core::ptr::addr_of_mut!(BLOCK) = Some(new) };
    }
    ENV_LOCK.unlock();
    r.map(|_| ())
}

fn push(block: &mut Vec<u8>, name: &[u8], value: &[u8]) {
    block.extend_from_slice(name);
    block.push(b'=');
    block.extend_from_slice(value);
    block.push(0);
}
