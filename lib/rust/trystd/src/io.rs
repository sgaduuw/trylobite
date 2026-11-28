//! Reading and writing, as std::io has them: the `Read`, `Write`,
//! `BufRead` and `Seek` traits, an `Error` that carries the kernel's
//! error, and standard input, output and error.
//!
//! Standard output is line buffered: what is printed goes out at each
//! newline, when the buffer fills, before a child starts, and when the
//! program ends through `main!` or `process::exit`. Standard error is
//! not buffered.

use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;

use crate::sync::LibLock;
use crate::sys;

/// What went wrong: the kernel's error (a negative E_ number), or one
/// the library found itself.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Error {
    repr: Repr,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Repr {
    Os(i32),
    Simple(ErrorKind, &'static str),
}

/// The kind of an error, to match on, as std's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum ErrorKind {
    NotFound,
    PermissionDenied,
    AlreadyExists,
    NotADirectory,
    IsADirectory,
    DirectoryNotEmpty,
    InvalidInput,
    InvalidData,
    InvalidFilename,
    TimedOut,
    WriteZero,
    StorageFull,
    FileTooLarge,
    ResourceBusy,
    BrokenPipe,
    Interrupted,
    ConnectionRefused,
    ConnectionReset,
    HostUnreachable,
    UnexpectedEof,
    OutOfMemory,
    Unsupported,
    Other,
}

pub type Result<T> = core::result::Result<T, Error>;

impl Error {
    /// The error for the kernel's (negative) error number `code`.
    pub const fn from_raw(code: i32) -> Error {
        Error {
            repr: Repr::Os(code),
        }
    }

    /// An error the library or a program finds itself.
    pub const fn new(kind: ErrorKind, message: &'static str) -> Error {
        Error {
            repr: Repr::Simple(kind, message),
        }
    }

    /// The kernel's error number, if it came from the kernel.
    pub fn raw_os_error(&self) -> Option<i32> {
        match self.repr {
            Repr::Os(code) => Some(code),
            Repr::Simple(..) => None,
        }
    }

    pub fn kind(&self) -> ErrorKind {
        let code = match self.repr {
            Repr::Os(code) => code,
            Repr::Simple(kind, _) => return kind,
        };
        use ErrorKind::*;
        match code {
            sys::E_NOENT => NotFound,
            sys::E_NOTDIR => NotADirectory,
            sys::E_ISDIR => IsADirectory,
            sys::E_NOTEMPTY => DirectoryNotEmpty,
            sys::E_INVAL | sys::E_FAULT | sys::E_BADF => InvalidInput,
            sys::E_NAMETOOLONG => InvalidFilename,
            sys::E_EXIST => AlreadyExists,
            sys::E_NOSPC => StorageFull,
            sys::E_FBIG => FileTooLarge,
            sys::E_BUSY => ResourceBusy,
            sys::E_PERM => PermissionDenied,
            sys::E_PIPE => BrokenPipe,
            sys::E_TIMEDOUT => TimedOut,
            sys::E_NOROUTE => HostUnreachable,
            sys::E_REFUSED => ConnectionRefused,
            sys::E_RESET => ConnectionReset,
            sys::E_NOMEM => OutOfMemory,
            sys::E_NOEXEC => InvalidData,
            sys::E_INTR => Interrupted,
            _ => Other,
        }
    }

    /// What went wrong, in words: what Display says, without a number
    /// for a code the library does not know, and without core::fmt.
    pub fn description(&self) -> &'static str {
        self.message()
    }

    fn message(&self) -> &'static str {
        let code = match self.repr {
            Repr::Os(code) => code,
            Repr::Simple(_, message) => return message,
        };
        match code {
            sys::E_NOENT => "no such file or directory",
            sys::E_NOTDIR => "not a directory",
            sys::E_ISDIR => "is a directory",
            sys::E_BADF => "bad descriptor",
            sys::E_MFILE => "too many open files",
            sys::E_INVAL => "invalid argument",
            sys::E_NAMETOOLONG => "name too long",
            sys::E_FAULT => "bad address",
            sys::E_NOEXEC => "not a program",
            sys::E_IO => "input/output error",
            sys::E_EXIST => "already exists",
            sys::E_NOSPC => "no space left",
            sys::E_NOTEMPTY => "directory not empty",
            sys::E_FBIG => "file too large",
            sys::E_BUSY => "busy",
            sys::E_NOROOM => "buffer too small",
            sys::E_PERM => "not allowed",
            sys::E_PIPE => "broken pipe",
            sys::E_INTR => "interrupted",
            sys::E_TIMEDOUT => "timed out",
            sys::E_NOROUTE => "no route to host",
            sys::E_REFUSED => "connection refused",
            sys::E_RESET => "connection reset",
            sys::E_NOFS => "no filesystem",
            sys::E_NOMEM => "out of memory",
            sys::E_NOPROC => "no such process or program",
            sys::E_NOSLOT => "no free process slot",
            _ => "system error",
        }
    }
}

impl From<ErrorKind> for Error {
    fn from(kind: ErrorKind) -> Error {
        Error::new(kind, "error")
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.repr {
            Repr::Os(code) if self.message() == "system error" => write!(f, "system error {code}"),
            _ => f.write_str(self.message()),
        }
    }
}

impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.repr {
            Repr::Os(code) => write!(
                f,
                "Os {{ code: {code}, kind: {:?}, message: {:?} }}",
                self.kind(),
                self.message()
            ),
            Repr::Simple(kind, message) => write!(f, "{kind:?}: {message}"),
        }
    }
}

const INVALID_UTF8: Error =
    Error::new(ErrorKind::InvalidData, "stream did not contain valid UTF-8");
const UNEXPECTED_EOF: Error = Error::new(ErrorKind::UnexpectedEof, "failed to fill whole buffer");
const WRITE_ZERO: Error = Error::new(ErrorKind::WriteZero, "failed to write whole buffer");

/// A source of bytes.
pub trait Read {
    /// Read into `buf`: how many bytes, 0 at the end.
    fn read(&mut self, buf: &mut [u8]) -> Result<usize>;

    /// Read to the end, appending to `buf`: how many bytes.
    fn read_to_end(&mut self, buf: &mut Vec<u8>) -> Result<usize> {
        let start = buf.len();
        let mut chunk = [0u8; CHUNK];
        loop {
            match self.read(&mut chunk)? {
                0 => return Ok(buf.len() - start),
                n => buf.extend_from_slice(&chunk[..n]),
            }
        }
    }

    /// Read to the end, appending to `s`; InvalidData, with `s` as it
    /// was, if what came is not UTF-8.
    fn read_to_string(&mut self, s: &mut String) -> Result<usize> {
        let mut bytes = Vec::new();
        let n = self.read_to_end(&mut bytes)?;
        s.push_str(core::str::from_utf8(&bytes).map_err(|_| INVALID_UTF8)?);
        Ok(n)
    }

    /// Fill `buf` exactly: UnexpectedEof if the end comes first.
    fn read_exact(&mut self, mut buf: &mut [u8]) -> Result<()> {
        while !buf.is_empty() {
            match self.read(buf)? {
                0 => return Err(UNEXPECTED_EOF),
                n => buf = &mut buf[n..],
            }
        }
        Ok(())
    }

    /// An iterator over the bytes, each a `Result`.
    fn bytes(self) -> Bytes<Self>
    where
        Self: Sized,
    {
        Bytes { inner: self }
    }
}

/// How much `read_to_end` and `copy` move at a time: a block's worth is
/// the most one read of a file gives.
const CHUNK: usize = 256;

/// A sink for bytes.
pub trait Write {
    /// Write some of `buf`: how many bytes were taken.
    fn write(&mut self, buf: &[u8]) -> Result<usize>;

    /// Send on whatever is buffered.
    fn flush(&mut self) -> Result<()> {
        Ok(())
    }

    /// Write all of `buf`, as many writes as it takes.
    fn write_all(&mut self, mut buf: &[u8]) -> Result<()> {
        while !buf.is_empty() {
            match self.write(buf)? {
                0 => return Err(WRITE_ZERO),
                n => buf = &buf[n..],
            }
        }
        Ok(())
    }

    /// Write formatted text: what `write!` and `writeln!` call.
    fn write_fmt(&mut self, args: fmt::Arguments<'_>) -> Result<()> {
        struct Adapter<'a, W: ?Sized> {
            inner: &'a mut W,
            error: Option<Error>,
        }
        impl<W: Write + ?Sized> fmt::Write for Adapter<'_, W> {
            fn write_str(&mut self, s: &str) -> fmt::Result {
                self.inner.write_all(s.as_bytes()).map_err(|e| {
                    self.error = Some(e);
                    fmt::Error
                })
            }
        }
        let mut out = Adapter {
            inner: self,
            error: None,
        };
        match fmt::write(&mut out, args) {
            Ok(()) => Ok(()),
            Err(_) => Err(out
                .error
                .unwrap_or(Error::new(ErrorKind::Other, "formatter error"))),
        }
    }
}

/// Where to seek from, as std's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SeekFrom {
    Start(u64),
    End(i64),
    Current(i64),
}

pub trait Seek {
    /// Move to a position: the new one, from the start.
    fn seek(&mut self, pos: SeekFrom) -> Result<u64>;

    fn rewind(&mut self) -> Result<()> {
        self.seek(SeekFrom::Start(0)).map(|_| ())
    }

    fn stream_position(&mut self) -> Result<u64> {
        self.seek(SeekFrom::Current(0))
    }
}

/// A reader with a buffer, read a line at a time.
pub trait BufRead: Read {
    /// What is buffered, reading more if nothing is: empty at the end.
    fn fill_buf(&mut self) -> Result<&[u8]>;

    /// Mark `n` bytes of the buffer used.
    fn consume(&mut self, n: usize);

    /// Read up to and including `byte`, or to the end, appending to
    /// `buf`: how many bytes, 0 at the end.
    fn read_until(&mut self, byte: u8, buf: &mut Vec<u8>) -> Result<usize> {
        let mut read = 0;
        loop {
            let (done, used) = {
                let available = self.fill_buf()?;
                match available.iter().position(|&b| b == byte) {
                    Some(i) => {
                        buf.extend_from_slice(&available[..=i]);
                        (true, i + 1)
                    }
                    None => {
                        buf.extend_from_slice(available);
                        (available.is_empty(), available.len())
                    }
                }
            };
            self.consume(used);
            read += used;
            if done {
                return Ok(read);
            }
        }
    }

    /// Read a line, its newline included, appending to `s`: how many
    /// bytes, 0 at the end.
    fn read_line(&mut self, s: &mut String) -> Result<usize> {
        let mut bytes = Vec::new();
        let n = self.read_until(b'\n', &mut bytes)?;
        s.push_str(core::str::from_utf8(&bytes).map_err(|_| INVALID_UTF8)?);
        Ok(n)
    }

    /// The lines, each without its newline (or "\r\n").
    fn lines(self) -> Lines<Self>
    where
        Self: Sized,
    {
        Lines { inner: self }
    }

    /// The pieces between each `byte`, without it.
    fn split(self, byte: u8) -> Split<Self>
    where
        Self: Sized,
    {
        Split { inner: self, byte }
    }
}

pub struct Lines<B> {
    inner: B,
}

impl<B: BufRead> Iterator for Lines<B> {
    type Item = Result<String>;

    fn next(&mut self) -> Option<Result<String>> {
        let mut line = String::new();
        match self.inner.read_line(&mut line) {
            Ok(0) => None,
            Ok(_) => {
                if line.ends_with('\n') {
                    line.pop();
                    if line.ends_with('\r') {
                        line.pop();
                    }
                }
                Some(Ok(line))
            }
            Err(e) => Some(Err(e)),
        }
    }
}

pub struct Split<B> {
    inner: B,
    byte: u8,
}

impl<B: BufRead> Iterator for Split<B> {
    type Item = Result<Vec<u8>>;

    fn next(&mut self) -> Option<Result<Vec<u8>>> {
        let mut piece = Vec::new();
        match self.inner.read_until(self.byte, &mut piece) {
            Ok(0) => None,
            Ok(_) => {
                if piece.last() == Some(&self.byte) {
                    piece.pop();
                }
                Some(Ok(piece))
            }
            Err(e) => Some(Err(e)),
        }
    }
}

pub struct Bytes<R> {
    inner: R,
}

impl<R: Read> Iterator for Bytes<R> {
    type Item = Result<u8>;

    fn next(&mut self) -> Option<Result<u8>> {
        let mut b = [0u8];
        match self.inner.read(&mut b) {
            Ok(0) => None,
            Ok(_) => Some(Ok(b[0])),
            Err(e) => Some(Err(e)),
        }
    }
}

/// A reader with a buffer in front, for `BufRead`.
pub struct BufReader<R> {
    inner: R,
    buf: [u8; CHUNK],
    pos: usize,
    len: usize,
}

impl<R: Read> BufReader<R> {
    pub fn new(inner: R) -> BufReader<R> {
        BufReader {
            inner,
            buf: [0; CHUNK],
            pos: 0,
            len: 0,
        }
    }

    pub fn get_ref(&self) -> &R {
        &self.inner
    }

    pub fn into_inner(self) -> R {
        self.inner
    }
}

impl<R: Read> Read for BufReader<R> {
    fn read(&mut self, out: &mut [u8]) -> Result<usize> {
        if self.pos == self.len && out.len() >= CHUNK {
            return self.inner.read(out);
        }
        let available = self.fill_buf()?;
        let n = available.len().min(out.len());
        out[..n].copy_from_slice(&available[..n]);
        self.consume(n);
        Ok(n)
    }
}

impl<R: Read> BufRead for BufReader<R> {
    fn fill_buf(&mut self) -> Result<&[u8]> {
        if self.pos == self.len {
            self.len = self.inner.read(&mut self.buf)?;
            self.pos = 0;
        }
        Ok(&self.buf[self.pos..self.len])
    }

    fn consume(&mut self, n: usize) {
        self.pos = (self.pos + n).min(self.len);
    }
}

impl Read for &[u8] {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let n = self.len().min(buf.len());
        buf[..n].copy_from_slice(&self[..n]);
        *self = &self[n..];
        Ok(n)
    }
}

impl BufRead for &[u8] {
    fn fill_buf(&mut self) -> Result<&[u8]> {
        Ok(self)
    }

    fn consume(&mut self, n: usize) {
        *self = &self[n.min(self.len())..];
    }
}

impl Write for Vec<u8> {
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        self.extend_from_slice(buf);
        Ok(buf.len())
    }
}

impl<R: Read + ?Sized> Read for &mut R {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        (**self).read(buf)
    }
}

impl<W: Write + ?Sized> Write for &mut W {
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        (**self).write(buf)
    }

    fn flush(&mut self) -> Result<()> {
        (**self).flush()
    }
}

/// Copy everything from `reader` to `writer`: how many bytes.
pub fn copy<R: Read + ?Sized, W: Write + ?Sized>(reader: &mut R, writer: &mut W) -> Result<u64> {
    let mut chunk = [0u8; CHUNK];
    let mut total = 0u64;
    loop {
        match reader.read(&mut chunk)? {
            0 => return Ok(total),
            n => {
                writer.write_all(&chunk[..n])?;
                total += n as u64;
            }
        }
    }
}

// --- the descriptors underneath -------------------------------------------------

/// Read from descriptor `fd` into `buf`.
pub(crate) fn read_fd(fd: i32, buf: &mut [u8]) -> Result<usize> {
    let n = sys::call(
        sys::SYS_READ,
        &[fd, buf.as_mut_ptr() as i32, buf.len() as i32],
    );
    sys::check(n).map(|n| n as usize)
}

/// Write to descriptor `fd` from `buf`.
pub(crate) fn write_fd(fd: i32, buf: &[u8]) -> Result<usize> {
    let n = sys::call(sys::SYS_WRITE, &[fd, buf.as_ptr() as i32, buf.len() as i32]);
    sys::check(n).map(|n| n as usize)
}

/// The size of the terminal behind standard output, as `(columns, rows)`,
/// as the terminal_size crate gives it; None when standard output is not
/// the console (a file, a pipe) or the machine does not know the size.
/// Ask again before each screen: the console follows the terminal as it
/// is resized.
pub fn terminal_size() -> Option<(usize, usize)> {
    terminal_size_of(1)
}

/// Whether descriptor `fd` is the console, as Unix's isatty: only the
/// console answers IO_WINSIZE.
pub fn is_terminal(fd: i32) -> bool {
    sys::call(sys::SYS_IOCALL, &[fd, sys::IO_WINSIZE, 0, 0]) >= 0
}

/// The same for descriptor `fd` (IO_WINSIZE).
pub fn terminal_size_of(fd: i32) -> Option<(usize, usize)> {
    if sys::call(sys::SYS_IOCALL, &[fd, sys::IO_WINSIZE, 0, 0]) < 0 {
        return None;
    }
    let (rows, columns) = (sys::more(0), sys::more(1));
    (rows > 0 && columns > 0).then_some((columns as usize, rows as usize))
}

/// Whether descriptor `fd` is the console, as std's `IsTerminal`: only
/// the console answers IO_WINSIZE, even when it does not know its size.
/// A pager asks it of standard input, to find where its keys come from.
pub fn is_terminal(fd: i32) -> bool {
    sys::call(sys::SYS_IOCALL, &[fd, sys::IO_WINSIZE, 0, 0]) >= 0
}

// --- standard input, output and error -------------------------------------------

/// The buffers behind standard input and output: one each per program,
/// shared by its threads, each part held by its lock while in use.
struct Std {
    inbuf: [u8; CHUNK],
    inpos: usize,
    inlen: usize,
    outbuf: [u8; CHUNK],
    outlen: usize,
}

static mut STD: Std = Std {
    inbuf: [0; CHUNK],
    inpos: 0,
    inlen: 0,
    outbuf: [0; CHUNK],
    outlen: 0,
};

/// Held while a thread uses inbuf, inpos and inlen.
static IN: LibLock = LibLock::new();
/// Held while a thread uses outbuf and outlen: for a whole print!, so
/// that threads printing at once do not mix their lines.
static OUT: LibLock = LibLock::new();

fn std() -> &'static mut Std {
    // Only under IN or OUT, as the fields go, and no reference is kept
    // past a call.
    unsafe { &mut *core::ptr::addr_of_mut!(STD) }
}

/// Standard input, buffered: `stdin().lines()`, `read_line`. Its threads
/// share one buffer: read it from one thread at a time.
pub struct Stdin {
    _private: (),
}

pub fn stdin() -> Stdin {
    Stdin { _private: () }
}

impl Stdin {
    /// Read a line, its newline included, appending to `s`.
    pub fn read_line(&self, s: &mut String) -> Result<usize> {
        BufRead::read_line(&mut stdin(), s)
    }

    /// The lines of standard input.
    pub fn lines(self) -> Lines<Stdin> {
        BufRead::lines(self)
    }

    pub fn lock(&self) -> Stdin {
        stdin()
    }
}

impl Read for Stdin {
    fn read(&mut self, out: &mut [u8]) -> Result<usize> {
        IN.lock();
        let s = std();
        let r = if s.inpos == s.inlen {
            read_fd(sys::STDIN, out)
        } else {
            let n = (s.inlen - s.inpos).min(out.len());
            out[..n].copy_from_slice(&s.inbuf[s.inpos..s.inpos + n]);
            s.inpos += n;
            Ok(n)
        };
        IN.unlock();
        r
    }
}

impl BufRead for Stdin {
    fn fill_buf(&mut self) -> Result<&[u8]> {
        IN.lock();
        let s = std();
        if s.inpos == s.inlen {
            match read_fd(sys::STDIN, &mut s.inbuf) {
                Ok(n) => {
                    s.inlen = n;
                    s.inpos = 0;
                }
                Err(e) => {
                    IN.unlock();
                    return Err(e);
                }
            }
        }
        IN.unlock();
        Ok(&s.inbuf[s.inpos..s.inlen])
    }

    fn consume(&mut self, n: usize) {
        IN.lock();
        let s = std();
        s.inpos = (s.inpos + n).min(s.inlen);
        IN.unlock();
    }
}

/// Standard output, line buffered.
pub struct Stdout {
    /// Whether the thread holds OUT already (_print), so that a call
    /// does not take it again.
    held: bool,
}

pub fn stdout() -> Stdout {
    Stdout { held: false }
}

impl Stdout {
    pub fn lock(&self) -> Stdout {
        stdout()
    }
}

impl Write for Stdout {
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        if self.held {
            return Held.write(buf);
        }
        OUT.lock();
        let r = Held.write(buf);
        OUT.unlock();
        r
    }

    fn flush(&mut self) -> Result<()> {
        if self.held {
            return Held.flush();
        }
        OUT.lock();
        let r = Held.flush();
        OUT.unlock();
        r
    }
}

/// Standard output for a thread that holds OUT.
struct Held;

impl Write for Held {
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        let s = std();
        if s.outlen == 0 && buf.len() >= CHUNK {
            return write_fd(sys::STDOUT, buf);
        }
        let n = (CHUNK - s.outlen).min(buf.len());
        s.outbuf[s.outlen..s.outlen + n].copy_from_slice(&buf[..n]);
        s.outlen += n;
        if s.outlen == CHUNK || buf[..n].contains(&b'\n') {
            self.flush()?;
        }
        Ok(n)
    }

    fn flush(&mut self) -> Result<()> {
        let s = std();
        let mut at = 0;
        while at < s.outlen {
            match write_fd(sys::STDOUT, &s.outbuf[at..s.outlen]) {
                Ok(0) => {
                    s.outlen = 0;
                    return Err(WRITE_ZERO);
                }
                Ok(n) => at += n,
                Err(e) => {
                    s.outlen = 0;
                    return Err(e);
                }
            }
        }
        s.outlen = 0;
        Ok(())
    }
}

/// Standard error, not buffered.
pub struct Stderr {
    _private: (),
}

pub fn stderr() -> Stderr {
    Stderr { _private: () }
}

impl Write for Stderr {
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        write_fd(sys::STDERR, buf)
    }
}

#[doc(hidden)]
pub fn _print(args: fmt::Arguments<'_>) {
    OUT.lock();
    let _ = Stdout { held: true }.write_fmt(args);
    OUT.unlock();
}

#[doc(hidden)]
pub fn _eprint(args: fmt::Arguments<'_>) {
    OUT.lock(); // standard output first, and no print! between
    let _ = Held.flush();
    let _ = stderr().write_fmt(args);
    OUT.unlock();
}

// --- lines without core::fmt -----------------------------------------------------

/// How long a `Line` may grow: a path and words about it fit.
pub const LINE_MAX: usize = 512;

/// A line of output put together on the stack and written at once,
/// without core::fmt: `Line::new().str("wc: ").str(name).error(&e).eprint()`.
///
/// core::fmt is some 6,000 trytes of a program and about 1,000 steps a
/// number. A program that stays under half a page (some 9,800 trytes)
/// runs in its four pages, as an assembly one does, and one past it takes
/// a fifth (docs/kernel.md, memory map), so the small tools of bin/ write
/// with this rather than `println!`. What would run past `LINE_MAX` is
/// dropped.
pub struct Line {
    buf: [u8; LINE_MAX],
    len: usize,
}

impl Default for Line {
    fn default() -> Self {
        Self::new()
    }
}

impl Line {
    pub const fn new() -> Line {
        Line { buf: [0; LINE_MAX], len: 0 }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.buf[..self.len]
    }

    /// Add bytes. The length is read and written once: a usize in
    /// memory is four trytes, loaded and stored by helper calls.
    pub fn bytes(&mut self, s: &[u8]) -> &mut Line {
        let len = self.len;
        let n = s.len().min(LINE_MAX - len);
        self.buf[len..len + n].copy_from_slice(&s[..n]);
        self.len = len + n;
        self
    }

    pub fn str(&mut self, s: &str) -> &mut Line {
        self.bytes(s.as_bytes())
    }

    pub fn byte(&mut self, b: u8) -> &mut Line {
        self.bytes(&[b])
    }

    /// `s`, then spaces to fill `width` columns (`{s:<width}`).
    pub fn str_left(&mut self, s: &str, width: usize) -> &mut Line {
        self.str(s);
        for _ in s.len()..width {
            self.byte(b' ');
        }
        self
    }

    /// `n` in decimal.
    pub fn num(&mut self, n: i64) -> &mut Line {
        self.num_right(n, 0)
    }

    /// `n` in decimal, right-aligned in `width` columns (`{n:>width}`).
    /// A number that fits a u32 is divided as one: a 64-bit division is
    /// a helper of some 3,000 steps.
    pub fn num_right(&mut self, n: i64, width: usize) -> &mut Line {
        let mut digits = [b' '; 24];
        let mut k = digits.len();
        let mut m = n.unsigned_abs();
        while m > u32::MAX as u64 {
            k -= 1;
            digits[k] = b'0' + (m % 10) as u8;
            m /= 10;
        }
        let mut m = m as u32;
        loop {
            k -= 1;
            digits[k] = b'0' + (m % 10) as u8;
            m /= 10;
            if m == 0 {
                break;
            }
        }
        if n < 0 {
            k -= 1;
            digits[k] = b'-';
        }
        let k = k.min(digits.len().saturating_sub(width));
        self.bytes(&digits[k..])
    }

    /// What `e` says went wrong.
    pub fn error(&mut self, e: &Error) -> &mut Line {
        self.str(e.description())
    }

    /// An IPv4 address as a.b.c.d.
    pub fn ip(&mut self, a: crate::net::Ipv4Addr) -> &mut Line {
        for (i, o) in a.octets().into_iter().enumerate() {
            if i > 0 {
                self.byte(b'.');
            }
            self.num(o as i64);
        }
        self
    }

    /// Write the line to standard output, with a newline, and start
    /// again. Standard output is line buffered, so it goes out now.
    pub fn print(&mut self) -> Result<()> {
        self.byte(b'\n');
        let r = stdout().write_all(self.as_bytes()).and_then(|()| stdout().flush());
        self.len = 0;
        r
    }

    /// Write the line to standard error, with a newline, after what
    /// standard output holds, and start again.
    pub fn eprint(&mut self) {
        self.byte(b'\n');
        let _ = stdout().flush();
        let _ = stderr().write_all(self.as_bytes());
        self.len = 0;
    }
}
