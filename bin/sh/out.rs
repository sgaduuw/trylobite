//! Output without core::fmt or the heap: bytes and numbers gathered in a
//! small buffer and written to a descriptor by number, so that what the
//! shell prints goes wherever descriptor 1 or 2 points at the time.

use core::mem::ManuallyDrop;

use trystd::fs::{File, OwnedFd};
use trystd::prelude::*;

/// Descriptor `fd` as a File that is never closed by dropping it.
pub fn fd_file(fd: i32) -> ManuallyDrop<File> {
    ManuallyDrop::new(File::from_fd(OwnedFd::from_raw(fd)))
}

const OUT_MAX: usize = 120;

pub struct Out {
    fd: i32,
    buf: [u8; OUT_MAX],
    len: usize,
}

impl Out {
    pub const fn new(fd: i32) -> Out {
        Out { fd, buf: [0; OUT_MAX], len: 0 }
    }

    /// Standard error, for what the shell says about a command.
    pub const fn err() -> Out {
        Out::new(2)
    }

    pub fn b(&mut self, s: &[u8]) -> &mut Out {
        for &c in s {
            self.c(c);
        }
        self
    }

    pub fn c(&mut self, c: u8) -> &mut Out {
        if self.len == OUT_MAX {
            self.flush();
        }
        self.buf[self.len] = c;
        self.len += 1;
        self
    }

    /// `n` copies of `c`, none if `n` is not positive.
    pub fn rep(&mut self, n: isize, c: u8) -> &mut Out {
        for _ in 0..n.max(0) {
            self.c(c);
        }
        self
    }

    /// `n` in decimal.
    pub fn n(&mut self, n: i32) -> &mut Out {
        if n < 0 {
            self.c(b'-');
        }
        let mut m = n.unsigned_abs();
        let mut digits = [0u8; 10];
        let mut k = digits.len();
        loop {
            k -= 1;
            digits[k] = b'0' + (m % 10) as u8;
            m /= 10;
            if m == 0 {
                break;
            }
        }
        self.b(&digits[k..])
    }

    /// A newline, and out it goes.
    pub fn nl(&mut self) {
        self.c(b'\n');
        self.flush();
    }

    pub fn flush(&mut self) {
        if self.len > 0 {
            // Nobody to tell when the console is gone or a pipe's reader left.
            let _ = fd_file(self.fd).write_all(&self.buf[..self.len]);
            self.len = 0;
        }
    }
}
