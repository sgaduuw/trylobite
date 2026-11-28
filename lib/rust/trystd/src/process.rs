//! Processes, as std::process has them: starting programs from the
//! disk as children (`Command`), waiting for them, and ending this one.
//!
//! A child gets copies of this program's descriptors, so its standard
//! input, output and error are this program's unless `Command` says
//! otherwise: `Stdio::piped()` gives this program the other end of a
//! pipe, and `Stdio::from(file)` hands the child a file.

use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;

use crate::fs::{File, OwnedFd};
use crate::io::{self, Read, Write};
use crate::sys::{self, CPath, FS, PIPE};

/// End this program with exit code `code`, after what standard output
/// holds has gone out.
pub fn exit(code: i32) -> ! {
    let _ = io::stdout().flush();
    sys::exit_now(code)
}

/// End this program at once, as a panic does.
pub fn abort() -> ! {
    crate::abort()
}

/// This process's number.
pub fn id() -> u32 {
    sys::call(sys::SYS_GETPID, &[]) as u32
}

/// What a child's standard input, output or error is to be.
pub struct Stdio(How);

enum How {
    Inherit,
    Piped,
    Fd(OwnedFd),
}

impl Stdio {
    /// This program's own (the default).
    pub fn inherit() -> Stdio {
        Stdio(How::Inherit)
    }

    /// A pipe, whose other end this program gets, as `Child`'s `stdin`,
    /// `stdout` or `stderr`.
    pub fn piped() -> Stdio {
        Stdio(How::Piped)
    }
}

impl From<File> for Stdio {
    fn from(file: File) -> Stdio {
        Stdio(How::Fd(file.into_fd()))
    }
}

impl From<OwnedFd> for Stdio {
    fn from(fd: OwnedFd) -> Stdio {
        Stdio(How::Fd(fd))
    }
}

/// A program to start: `Command::new("wc").arg("notes").status()`.
pub struct Command {
    program: Vec<u8>,
    args: Vec<u8>,
    count: usize,
    stdio: [Option<Stdio>; 3],
}

impl Command {
    /// The program: a path if it has a slash, else the file of that name
    /// in /bin, as the shell finds one. It is also the child's first
    /// argument.
    pub fn new<S: AsRef<[u8]>>(program: S) -> Command {
        let program = program.as_ref();
        let mut command = Command {
            program: Vec::from(program),
            args: Vec::new(),
            count: 0,
            stdio: [None, None, None],
        };
        command.arg(program);
        command
    }

    pub fn arg<S: AsRef<[u8]>>(&mut self, arg: S) -> &mut Command {
        self.args.extend_from_slice(arg.as_ref());
        self.args.push(0);
        self.count += 1;
        self
    }

    pub fn args<I, S>(&mut self, args: I) -> &mut Command
    where
        I: IntoIterator<Item = S>,
        S: AsRef<[u8]>,
    {
        for arg in args {
            self.arg(arg);
        }
        self
    }

    pub fn stdin<T: Into<Stdio>>(&mut self, how: T) -> &mut Command {
        self.stdio[0] = Some(how.into());
        self
    }

    pub fn stdout<T: Into<Stdio>>(&mut self, how: T) -> &mut Command {
        self.stdio[1] = Some(how.into());
        self
    }

    pub fn stderr<T: Into<Stdio>>(&mut self, how: T) -> &mut Command {
        self.stdio[2] = Some(how.into());
        self
    }

    /// Start it. Arguments past ARG_MAX trytes in all are E_INVAL, as the
    /// kernel says.
    pub fn spawn(&mut self) -> io::Result<Child> {
        let mut path = Vec::new();
        if !self.program.contains(&b'/') {
            path.extend_from_slice(b"/bin/");
        }
        path.extend_from_slice(&self.program);
        let path = CPath::new(&path)?;
        let _ = io::stdout().flush();

        // Each redirected descriptor: this program's own is kept aside
        // in a spare descriptor the child does not get, the child's put
        // in its place, and this program's put back once it has started.
        let mut saved: [Option<OwnedFd>; 3] = [None, None, None];
        let mut redirected = [false; 3];
        let mut ends: [Option<OwnedFd>; 3] = [None, None, None];
        let mut result = Ok(());
        for fd in 0..3 {
            let Some(Stdio(how)) = self.stdio[fd].take() else {
                continue;
            };
            let theirs = match how {
                How::Inherit => continue,
                How::Fd(f) => f,
                How::Piped => match pipe() {
                    Ok((read, write)) => {
                        let (ours, theirs) = if fd == 0 {
                            (write, read)
                        } else {
                            (read, write)
                        };
                        let _ = ours.set_inherit(false);
                        ends[fd] = Some(ours);
                        theirs
                    }
                    Err(e) => {
                        result = Err(e);
                        break;
                    }
                },
            };
            match keep_aside(fd as i32) {
                Ok(kept) => saved[fd] = kept,
                Err(e) => {
                    result = Err(e);
                    break;
                }
            }
            if let Err(e) = dup2(theirs.raw(), fd as i32) {
                result = Err(e);
                break;
            }
            redirected[fd] = true;
            // Dropping theirs closes this program's copy of it.
        }
        let started = result.and_then(|()| {
            FS.call(
                sys::FS_SPAWN,
                &[
                    path.ptr(),
                    self.args.as_ptr() as i32,
                    self.args.len() as i32,
                ],
            )
        });
        for (fd, kept) in saved.iter_mut().enumerate() {
            if let Some(kept) = kept.take() {
                let _ = dup2(kept.raw(), fd as i32);
            } else if redirected[fd] {
                // This program had none there: it goes back to none.
                sys::call(sys::SYS_CLOSE, &[fd as i32]);
            }
        }
        let pid = started?;
        let [stdin, stdout, stderr] = ends;
        Ok(Child {
            pid,
            status: None,
            stdin: stdin.map(|fd| ChildStdin { fd }),
            stdout: stdout.map(|fd| ChildStdout { fd }),
            stderr: stderr.map(|fd| ChildStderr { fd }),
        })
    }

    /// Start it and wait for it to end.
    pub fn status(&mut self) -> io::Result<ExitStatus> {
        self.spawn()?.wait()
    }

    /// Start it with its output piped back, and wait for it to end:
    /// its status and all it wrote to standard output and error.
    pub fn output(&mut self) -> io::Result<Output> {
        if self.stdout_unset() {
            self.stdout(Stdio::piped());
        }
        let mut child = self.spawn()?;
        child.stdin.take();
        let mut stdout = Vec::new();
        if let Some(mut out) = child.stdout.take() {
            out.read_to_end(&mut stdout)?;
        }
        let mut stderr = Vec::new();
        if let Some(mut err) = child.stderr.take() {
            err.read_to_end(&mut stderr)?;
        }
        let status = child.wait()?;
        Ok(Output {
            status,
            stdout,
            stderr,
        })
    }

    fn stdout_unset(&self) -> bool {
        self.stdio[1].is_none()
    }
}

/// Make descriptor `to` a copy of `fd`.
fn dup2(fd: i32, to: i32) -> io::Result<()> {
    sys::check(sys::call(sys::SYS_DUP2, &[fd, to])).map(|_| ())
}

/// A copy of descriptor `fd` in a free descriptor that children do not
/// get, or None if `fd` is not open.
fn keep_aside(fd: i32) -> io::Result<Option<OwnedFd>> {
    if !is_open(fd) {
        return Ok(None);
    }
    for spare in (sys::STDERR + 1)..sys::NDESC {
        if !is_open(spare) {
            dup2(fd, spare)?;
            let kept = OwnedFd::from_raw(spare);
            kept.set_inherit(false)?;
            return Ok(Some(kept));
        }
    }
    Err(io::Error::from_raw(sys::E_MFILE))
}

/// Whether descriptor `fd` names something: dup2 onto itself changes
/// nothing (fdflags would clear its flags), and is E_BADF if it does not.
fn is_open(fd: i32) -> bool {
    sys::call(sys::SYS_DUP2, &[fd, fd]) >= 0
}

/// A new pipe from the pipe server: its read end, then its write end.
pub fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let read = PIPE.call(sys::PP_PIPE, &[]);
    let write = sys::more(0);
    match read {
        Ok(read) => Ok((OwnedFd::from_raw(read), OwnedFd::from_raw(write))),
        Err(e) => {
            if write >= 0 && e.raw_os_error() == Some(sys::E_MFILE) {
                // The read end was given and has to go back.
                sys::call(sys::SYS_CLOSE, &[write]);
            }
            Err(e)
        }
    }
}

/// A child process. Dropping it neither waits for it nor ends it.
pub struct Child {
    pid: i32,
    status: Option<ExitStatus>,
    pub stdin: Option<ChildStdin>,
    pub stdout: Option<ChildStdout>,
    pub stderr: Option<ChildStderr>,
}

impl Child {
    pub fn id(&self) -> u32 {
        self.pid as u32
    }

    /// Wait for it to end (SYS_WAIT), closing its standard input first
    /// if this program holds the pipe to it.
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        self.stdin.take();
        if let Some(status) = self.status {
            return Ok(status);
        }
        let how = sys::check(sys::call(sys::SYS_WAIT, &[self.pid]))?;
        let status = ExitStatus {
            how,
            code: sys::more(0),
        };
        self.status = Some(status);
        Ok(status)
    }

    /// End it with SIGKILL; `wait` then says it was killed.
    pub fn kill(&mut self) -> io::Result<()> {
        self.signal(sys::SIGKILL)
    }

    /// Send it signal `sig` (SYS_KILL, `signal`).
    pub fn signal(&mut self, sig: i32) -> io::Result<()> {
        if self.status.is_some() {
            return Ok(());
        }
        sys::check(sys::call(sys::SYS_KILL, &[self.pid, sys::FOR_SELF, sig])).map(|_| ())
    }

    pub fn wait_with_output(mut self) -> io::Result<Output> {
        self.stdin.take();
        let mut stdout = Vec::new();
        if let Some(mut out) = self.stdout.take() {
            out.read_to_end(&mut stdout)?;
        }
        let mut stderr = Vec::new();
        if let Some(mut err) = self.stderr.take() {
            err.read_to_end(&mut stderr)?;
        }
        let status = self.wait()?;
        Ok(Output {
            status,
            stdout,
            stderr,
        })
    }
}

/// The write end of a pipe to a child's standard input.
pub struct ChildStdin {
    fd: OwnedFd,
}

impl Write for ChildStdin {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.fd.write(buf)
    }
}

/// The read end of a pipe from a child's standard output.
pub struct ChildStdout {
    fd: OwnedFd,
}

impl Read for ChildStdout {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.fd.read(buf)
    }
}

/// The read end of a pipe from a child's standard error.
pub struct ChildStderr {
    fd: OwnedFd,
}

impl Read for ChildStderr {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.fd.read(buf)
    }
}

/// How a child ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExitStatus {
    how: i32,
    code: i32,
}

impl ExitStatus {
    /// It exited with code 0.
    pub fn success(&self) -> bool {
        self.code() == Some(0)
    }

    /// The code it gave exit, if it exited.
    pub fn code(&self) -> Option<i32> {
        (self.how == sys::WAIT_EXITED).then_some(self.code)
    }

    /// It was killed (kill, or Ctrl-C).
    pub fn killed(&self) -> bool {
        self.how == sys::WAIT_KILLED
    }

    /// The signal that ended it, if one did (std's
    /// `ExitStatusExt::signal`).
    pub fn signal(&self) -> Option<i32> {
        self.killed().then_some(self.code)
    }

    /// The trap cause that ended it, if it faulted.
    pub fn fault(&self) -> Option<i32> {
        (self.how == sys::WAIT_FAULTED).then_some(self.code)
    }
}

impl fmt::Display for ExitStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(code) = self.code() {
            write!(f, "exit {code}")
        } else if let Some(cause) = self.fault() {
            write!(f, "fault {cause}")
        } else {
            match crate::signal::name(self.code) {
                Some(name) => write!(f, "killed by SIG{name}"),
                None => write!(f, "killed by signal {}", self.code),
            }
        }
    }
}

/// What `output` collects.
#[derive(Clone, Debug)]
pub struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// What `main!`'s function may return, as std's Termination: nothing,
/// an exit code, or a `Result` whose error is said on standard error as
/// "PROGRAM: ERROR" and gives exit code 1.
pub trait Termination {
    fn report(self) -> i32;
}

impl Termination for () {
    fn report(self) -> i32 {
        0
    }
}

impl Termination for i32 {
    fn report(self) -> i32 {
        self
    }
}

impl Termination for ExitCode {
    fn report(self) -> i32 {
        self.0
    }
}

impl<T: Termination, E: fmt::Display> Termination for Result<T, E> {
    fn report(self) -> i32 {
        match self {
            Ok(t) => t.report(),
            Err(e) => {
                let name = crate::env::args().next().unwrap_or("");
                let name = name.rsplit('/').next().unwrap_or(name);
                crate::eprintln!("{name}: {e}");
                1
            }
        }
    }
}

/// An exit code, as std's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExitCode(i32);

impl ExitCode {
    pub const SUCCESS: ExitCode = ExitCode(0);
    pub const FAILURE: ExitCode = ExitCode(1);
}

impl From<u8> for ExitCode {
    fn from(code: u8) -> ExitCode {
        ExitCode(code as i32)
    }
}

/// An error that is only a message, for `main!`'s function to return:
/// `Err(Message::new("cannot open"))?`.
pub struct Message(String);

impl Message {
    pub fn new<S: Into<String>>(s: S) -> Message {
        Message(s.into())
    }
}

impl fmt::Display for Message {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<io::Error> for Message {
    fn from(e: io::Error) -> Message {
        Message(alloc::format!("{e}"))
    }
}
