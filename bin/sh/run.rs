//! Running a line: its commands, their redirections and the pipes
//! between them, and waiting for the programs.
//!
//! A line is up to `STAGES` commands separated by |. Each command's words
//! are its name and arguments, less its redirections: < PATH makes the
//! file standard input, > PATH standard output, made empty or new, and
//! >> PATH standard output at the file's end, wherever they stand among
//! the words. The shell keeps its own standard input and output aside
//! (`SAVE_IN`, `SAVE_OUT`, out of children) while a line changes them,
//! and puts them back once it is done.
//!
//! In a pipeline each command's standard output is a pipe (the pipe
//! server's) that is the next one's standard input. Every program of the
//! line starts before the shell waits for any, so they run side by side,
//! and the shell keeps its end of each pipe out of the children
//! (FD_NOINHERIT), so that a reader sees the end once its writer has
//! gone. A built-in in a pipeline runs in the shell itself, once every
//! program has started; one is allowed per line, since two would wait
//! for each other.
//!
//! What runs a command is `start`; a scripting language (lists, && and
//! ||, if and for) would call `line` for each pipeline and look at
//! `status`.

use trystd::fs::{self, OpenOptions};
use trystd::prelude::*;
use trystd::process::{self, Child};
use trystd::{console, sys};

use crate::builtin::{self, Builtin};
use crate::fail;
use crate::lex::{Kind, Lexed, TOKS};
use crate::out::Out;

/// Commands a pipeline may have.
const STAGES: usize = 4;
/// Where the shell's standard input and output wait while a line has
/// others, and where a built-in's wait while the line's programs start.
const SAVE_IN: i32 = sys::NDESC - 2;
const SAVE_OUT: i32 = sys::NDESC - 1;
const PARK_IN: i32 = sys::NDESC - 4;
const PARK_OUT: i32 = sys::NDESC - 3;

/// Programs of the kernel image the shell starts by number (shell.s);
/// everything else is on the disk.
pub const PROGRAMS: &[(&[u8], i32)] = &[(b"pingpong", 3)];

/// A command's words, as token numbers: its name first.
#[derive(Clone, Copy)]
pub struct Words {
    at: [u8; TOKS],
    pub n: usize,
}

impl Words {
    pub fn at(&self, k: usize) -> usize {
        self.at[k] as usize
    }

    /// Word `k`, if there is one.
    pub fn get<'a>(&self, lx: &'a Lexed, k: usize) -> Option<&'a [u8]> {
        (k < self.n).then(|| lx.word(self.at(k)))
    }
}

/// What starting a command came to.
enum Started {
    Program(Child),
    Builtin(Builtin, Words),
    /// Redirections and no command.
    Nothing,
}

/// It has been said why the line stopped.
pub struct Stop;

pub struct Runner {
    /// The shell's descriptors 0 and 1 are aside.
    saved: bool,
    children: [Option<Child>; STAGES],
}

impl Runner {
    pub const fn new() -> Runner {
        Runner { saved: false, children: [None, None, None, None] }
    }

    /// Run a lexed line, then put the shell's descriptors back and wait
    /// for the programs it started.
    pub fn line(&mut self, lx: &Lexed) {
        let _ = self.stages(lx);
        self.finish();
    }

    fn stages(&mut self, lx: &Lexed) -> Result<(), Stop> {
        // Each command's tokens, from..to.
        let mut cut = [(0, 0); STAGES];
        let mut n = 0;
        let mut from = 0;
        for k in 0..=lx.n {
            if k == lx.n || lx.tok(k).kind == Kind::Pipe {
                if n == STAGES {
                    return say(b"sh: too many commands in the pipeline");
                }
                cut[n] = (from, k);
                n += 1;
                from = k + 1;
            }
        }
        if n == 1 {
            return match self.start(lx, cut[0])? {
                Started::Program(child) => {
                    self.children[0] = Some(child);
                    Ok(())
                }
                Started::Builtin(f, w) => {
                    f(lx, &w);
                    Ok(())
                }
                Started::Nothing => Ok(()),
            };
        }
        if cut[..n].iter().any(|&(f, t)| !has_word(lx, f, t)) {
            return say(b"sh: a command is missing around |");
        }
        self.save();
        let mut read_end = None;
        let mut parked: Option<(Builtin, Words)> = None;
        for (k, &range) in cut[..n].iter().enumerate() {
            // Standard input: the last pipe, or the shell's.
            let _ = fs::dup2(read_end.unwrap_or(SAVE_IN), sys::STDIN);
            if let Some(r) = read_end.take() {
                fs::close(r);
            }
            // Standard output: a new pipe, or the shell's for the last.
            if k + 1 == n {
                let _ = fs::dup2(SAVE_OUT, sys::STDOUT);
            } else {
                let (r, w) = match process::pipe() {
                    Ok(ends) => ends,
                    Err(e) => {
                        let code = e.raw_os_error().unwrap_or(0);
                        Out::err().b(b"sh: cannot make a pipe: ").n(code).nl();
                        return Err(Stop);
                    }
                };
                // The writer must not hold the read end.
                let _ = r.set_inherit(false);
                let _ = fs::dup2(w.raw(), sys::STDOUT);
                read_end = Some(r.into_raw());
            }
            match self.start(lx, range)? {
                Started::Program(child) => self.children[k] = Some(child),
                Started::Builtin(f, w) => {
                    if parked.is_some() {
                        return say(b"sh: one built-in to a pipeline");
                    }
                    parked = Some((f, w));
                    park(sys::STDIN, PARK_IN);
                    park(sys::STDOUT, PARK_OUT);
                }
                Started::Nothing => {}
            }
        }
        if let Some((f, w)) = parked {
            let _ = fs::dup2(PARK_IN, sys::STDIN);
            let _ = fs::dup2(PARK_OUT, sys::STDOUT);
            fs::close(PARK_IN);
            fs::close(PARK_OUT);
            f(lx, &w);
        }
        Ok(())
    }

    /// Start the command of tokens `from..to`: its redirections first,
    /// then a built-in (left to the caller to run), a program of the
    /// image, or a program file: a path if it has a slash, else the file
    /// of that name in /bin, as a Unix shell searches its PATH, with the
    /// words as its arguments, the command first.
    fn start(&mut self, lx: &Lexed, (from, to): (usize, usize)) -> Result<Started, Stop> {
        let mut words = Words { at: [0; TOKS], n: 0 };
        let mut k = from;
        while k < to {
            let t = lx.tok(k);
            let opens = match t.kind {
                Kind::In => OpenOptions::new().read(true).clone(),
                Kind::Out => OpenOptions::new().write(true).create(true).truncate(true).clone(),
                Kind::Append => OpenOptions::new().write(true).create(true).append(true).clone(),
                _ => {
                    words.at[words.n] = k as u8;
                    words.n += 1;
                    k += 1;
                    continue;
                }
            };
            if k + 1 == to || lx.tok(k + 1).kind != Kind::Word {
                return say(b"sh: which file?");
            }
            let path = lx.word(k + 1);
            let file = match opens.open(path) {
                Ok(file) => file,
                Err(e) => {
                    fail(path, &e);
                    return Err(Stop);
                }
            };
            self.save();
            let fd = if t.kind == Kind::In { sys::STDIN } else { sys::STDOUT };
            let file = file.into_fd();
            if file.raw() == fd {
                file.into_raw(); // it came there itself: keep it open
            } else {
                let _ = fs::dup2(file.raw(), fd);
            }
            k += 2;
        }
        let Some(name) = words.get(lx, 0) else {
            return Ok(Started::Nothing);
        };
        if let Some(f) = builtin::find(name) {
            return Ok(Started::Builtin(f, words));
        }
        let started = match PROGRAMS.iter().find(|&&(p, _)| p == name) {
            Some(&(_, number)) => process::spawn_image(number),
            None => {
                let mut path = [0u8; crate::LINE_MAX + 5];
                let mut n = 0;
                if !name.contains(&b'/') {
                    path[..5].copy_from_slice(b"/bin/");
                    n = 5;
                }
                path[n..n + name.len()].copy_from_slice(name);
                n += name.len();
                let mut args = [0u8; 2 * crate::LINE_MAX];
                let mut a = 0;
                for w in 0..words.n {
                    let word = lx.word(words.at(w));
                    args[a..a + word.len()].copy_from_slice(word);
                    args[a + word.len()] = 0;
                    a += word.len() + 1;
                }
                process::spawn_file(&path[..n], &args[..a])
            }
        };
        match started {
            Ok(child) => Ok(Started::Program(child)),
            Err(e) => {
                let mut out = Out::err();
                match e.raw_os_error().unwrap_or(0) {
                    sys::E_NOEXEC => out.b(b"sh: not a program: ").b(name),
                    sys::E_NOENT
                    | sys::E_NOTDIR
                    | sys::E_NOFS
                    | sys::E_NOPROC
                    | sys::E_NAMETOOLONG => out.b(b"sh: no such program: ").b(name),
                    code => out.b(b"sh: cannot start it: ").n(code),
                };
                out.nl();
                Err(Stop)
            }
        }
    }

    /// Keep the shell's standard input and output aside, out of
    /// children, the first time a line changes them.
    fn save(&mut self) {
        if !self.saved {
            self.saved = true;
            park(sys::STDIN, SAVE_IN);
            park(sys::STDOUT, SAVE_OUT);
        }
    }

    /// Put back what the line changed, close whatever a pipeline that
    /// stopped partway left open, so that its programs see their pipes
    /// end, and wait for the programs, in order.
    fn finish(&mut self) {
        if core::mem::replace(&mut self.saved, false) {
            restore(sys::STDIN, SAVE_IN);
            restore(sys::STDOUT, SAVE_OUT);
            for fd in sys::STDERR + 1..SAVE_IN {
                fs::close(fd);
            }
        }
        for child in self.children.iter_mut() {
            if let Some(mut child) = child.take() {
                reap(&mut child);
            }
        }
    }
}

/// Whether tokens `from..to` hold a command: a word that is not a
/// redirection's path.
fn has_word(lx: &Lexed, from: usize, to: usize) -> bool {
    (from..to).any(|k| {
        lx.tok(k).kind == Kind::Word
            && (k == from || !matches!(lx.tok(k - 1).kind, Kind::In | Kind::Out | Kind::Append))
    })
}

fn say<T>(what: &[u8]) -> Result<T, Stop> {
    Out::err().b(what).nl();
    Err(Stop)
}

/// Copy descriptor `fd` to `to`, kept out of children.
fn park(fd: i32, to: i32) {
    if fs::dup2(fd, to).is_ok() {
        let _ = fs::set_inherit(to, false);
    }
}

/// Point descriptor `fd` back at what `kept` held for it, and close
/// `kept`; with nothing kept, `fd` is closed.
fn restore(fd: i32, kept: i32) {
    fs::close(fd);
    let _ = fs::dup2(kept, fd);
    fs::close(kept);
}

/// Give the console to `child` while it runs, so that Ctrl-C ends it,
/// wait for it, and say how it ended if not with 0: on standard error,
/// since it is about the program, not its output. A shell whose input
/// is not the console (a remote shell's, bin/telnetd) leaves the console
/// to whoever has it.
fn reap(child: &mut Child) {
    let console = crate::on_console();
    if console {
        let _ = console::set_foreground(Some(child.id()));
    }
    let status = child.wait();
    // The console is the shell's again before another program can have
    // this one's number.
    if console {
        let _ = console::set_foreground(None);
    }
    let Ok(status) = status else { return };
    let mut out = Out::err();
    if let Some(code) = status.code() {
        if code == 0 {
            return;
        }
        out.b(b"sh: exit ").n(code);
    } else if let Some(cause) = status.fault() {
        out.b(b"sh: fault ").n(cause);
    } else if status.signal() == Some(sys::SIGPIPE) {
        return; // a writer whose reader left: as Unix shells, nothing to say
    } else {
        out.b(b"sh: killed");
    }
    out.nl();
}
