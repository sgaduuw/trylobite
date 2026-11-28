//! Running a pipeline: its commands, their redirections and the pipes
//! between them, and waiting for the programs.
//!
//! A pipeline is commands separated by |. Each command's words are its
//! name and arguments, less its redirections: < PATH makes the file
//! standard input, > PATH standard output, made empty or new, and >>
//! PATH standard output at the file's end, wherever they stand among
//! the words. Words of the form NAME=VALUE before the command's name
//! set variables: for that command alone, in its environment, if a name
//! follows, else in the shell. The shell keeps its own standard input
//! and output aside (`SAVE_IN`, `SAVE_OUT`, out of children) while a
//! line changes them, and puts them back once it is done.
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
//! A pipeline's status is its last command's: a program's exit code,
//! 128 and the signal for one a signal ended, 255 for a fault, a
//! built-in's own, and 127 or 126 for a program not found or not
//! started.

use trystd::env;
use trystd::fs::{self, OpenOptions};
use trystd::prelude::*;
use trystd::process::{self, Child};
use trystd::{console, sys};

use crate::Shell;
use crate::builtin::{self, Builtin};
use crate::expand::{Arg, assignment};
use crate::fail;
use crate::lex::{Kind, Tok};
use crate::out::Out;

/// Where the shell's standard input and output wait while a line has
/// others, and where a built-in's wait while the line's programs start.
const SAVE_IN: i32 = sys::NDESC - 2;
const SAVE_OUT: i32 = sys::NDESC - 1;
const PARK_IN: i32 = sys::NDESC - 4;
const PARK_OUT: i32 = sys::NDESC - 3;

/// Statuses of commands that never ran, as Unix shells give them.
pub const NOT_FOUND: i32 = 127;
pub const NOT_STARTED: i32 = 126;
/// The status of a command the shell stopped before it ran: a missing
/// file to redirect, a misplaced operator.
pub const FAILED: i32 = 1;

/// Programs of the kernel image the shell starts by number (shell.s);
/// everything else is on the disk.
pub const PROGRAMS: &[(&[u8], i32)] = &[(b"pingpong", 3)];

/// A command as typed: its words (assignments first, then its name and
/// arguments) and its redirections, each with the word naming its file.
pub struct Cmd {
    pub words: Vec<Tok>,
    pub redirs: Vec<(Kind, Tok)>,
}

/// The commands of a pipeline as typed, or why the line is not one.
pub fn parse(toks: &[Tok]) -> Result<Vec<Cmd>, &'static [u8]> {
    let mut cmds = Vec::new();
    let mut cmd = Cmd { words: Vec::new(), redirs: Vec::new() };
    let mut k = 0;
    while k < toks.len() {
        let t = &toks[k];
        match t.kind {
            Kind::Word => cmd.words.push(t.clone()),
            Kind::Pipe => {
                if cmd.words.is_empty() {
                    return Err(b"sh: a command is missing around |");
                }
                cmds.push(core::mem::replace(&mut cmd, Cmd { words: Vec::new(), redirs: Vec::new() }));
            }
            Kind::In | Kind::Out | Kind::Append => {
                match toks.get(k + 1) {
                    Some(path) if path.kind == Kind::Word => cmd.redirs.push((t.kind, path.clone())),
                    _ => return Err(b"sh: which file?"),
                }
                k += 1;
            }
        }
        k += 1;
    }
    if cmd.words.is_empty() && !cmds.is_empty() {
        return Err(b"sh: a command is missing around |");
    }
    if !cmd.words.is_empty() || !cmd.redirs.is_empty() {
        cmds.push(cmd);
    }
    Ok(cmds)
}

/// What starting a command came to.
enum Started {
    Program(Child),
    Builtin(Builtin, Vec<Arg>, Vec<(Vec<u8>, Vec<u8>)>),
    /// Redirections and assignments, and no command.
    Nothing,
}

/// It has been said why the line stopped; the status it leaves.
pub struct Stop(pub i32);

/// What the runner keeps while a pipeline runs.
pub struct Runner {
    /// The shell's descriptors 0 and 1 are aside.
    saved: bool,
    /// Each stage's program, if it started one.
    children: Vec<Option<Child>>,
}

impl Runner {
    pub const fn new() -> Runner {
        Runner { saved: false, children: Vec::new() }
    }
}

impl Shell {
    /// Run a pipeline, then put the shell's descriptors back and wait for
    /// the programs it started: its status.
    pub fn pipeline(&mut self, cmds: &[Cmd]) -> i32 {
        let r = self.stages(cmds);
        let waited = self.finish();
        match r {
            Err(Stop(status)) => status,
            Ok(Some(status)) => status, // the last command was a built-in
            Ok(None) => waited,
        }
    }

    /// Start every command; the status of the last if it ran in the
    /// shell.
    fn stages(&mut self, cmds: &[Cmd]) -> Result<Option<i32>, Stop> {
        let n = cmds.len();
        self.runner.children.clear();
        self.runner.children.resize_with(n, || None);
        if n == 1 {
            return match self.start(&cmds[0])? {
                Started::Program(child) => {
                    self.runner.children[0] = Some(child);
                    Ok(None)
                }
                Started::Builtin(f, args, assigns) => Ok(Some(self.builtin(f, &args, &assigns))),
                Started::Nothing => Ok(Some(0)),
            };
        }
        self.save();
        let mut read_end = None;
        let mut parked: Option<(Builtin, Vec<Arg>, Vec<(Vec<u8>, Vec<u8>)>)> = None;
        let mut last_builtin = false;
        for (k, cmd) in cmds.iter().enumerate() {
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
                        return Err(Stop(FAILED));
                    }
                };
                // The writer must not hold the read end.
                let _ = r.set_inherit(false);
                let _ = fs::dup2(w.raw(), sys::STDOUT);
                read_end = Some(r.into_raw());
            }
            match self.start(cmd)? {
                Started::Program(child) => self.runner.children[k] = Some(child),
                Started::Builtin(f, args, assigns) => {
                    if parked.is_some() {
                        return say(b"sh: one built-in to a pipeline");
                    }
                    parked = Some((f, args, assigns));
                    last_builtin = k + 1 == n;
                    park(sys::STDIN, PARK_IN);
                    park(sys::STDOUT, PARK_OUT);
                }
                Started::Nothing => {}
            }
        }
        if let Some((f, args, assigns)) = parked {
            let _ = fs::dup2(PARK_IN, sys::STDIN);
            let _ = fs::dup2(PARK_OUT, sys::STDOUT);
            fs::close(PARK_IN);
            fs::close(PARK_OUT);
            let status = self.builtin(f, &args, &assigns);
            if last_builtin {
                return Ok(Some(status));
            }
        }
        Ok(None)
    }

    /// Run built-in `f` with the assignments typed before it in the
    /// environment meanwhile.
    fn builtin(&mut self, f: Builtin, args: &[Arg], assigns: &[(Vec<u8>, Vec<u8>)]) -> i32 {
        let old = set_env(assigns);
        let status = f(self, args);
        restore_env(old);
        status
    }

    /// Start a command: its redirections first, then a built-in (left to
    /// the caller to run), a program of the image, or a program file: a
    /// path if it has a slash, else the first file of that name in a
    /// directory of $PATH, with the words as its arguments, the command
    /// first.
    fn start(&mut self, cmd: &Cmd) -> Result<Started, Stop> {
        for (kind, path) in &cmd.redirs {
            let opens = match kind {
                Kind::In => OpenOptions::new().read(true).clone(),
                Kind::Out => OpenOptions::new().write(true).create(true).truncate(true).clone(),
                _ => OpenOptions::new().write(true).create(true).append(true).clone(),
            };
            let mut paths = self.expand(&path.text);
            if paths.len() != 1 {
                return say(b"sh: which file?");
            }
            let path = paths.pop().unwrap_or_default();
            let file = match opens.open(&path) {
                Ok(file) => file,
                Err(e) => {
                    fail(&path, &e);
                    return Err(Stop(FAILED));
                }
            };
            self.save();
            let fd = if *kind == Kind::In { sys::STDIN } else { sys::STDOUT };
            let file = file.into_fd();
            if file.raw() == fd {
                file.into_raw(); // it came there itself: keep it open
            } else {
                let _ = fs::dup2(file.raw(), fd);
            }
        }
        // Assignments, then the words.
        let mut assigns = Vec::new();
        let mut words = cmd.words.iter().peekable();
        while let Some((name, value)) = words.peek().and_then(|w| assignment(&w.text)) {
            assigns.push((name.to_vec(), self.expand_one(value)));
            words.next();
        }
        let mut args = Vec::new();
        for w in words {
            for (k, text) in self.expand(&w.text).into_iter().enumerate() {
                // The spaces typed before the word, or one between the
                // arguments a value split into.
                let gap = if args.is_empty() { 0 } else if k == 0 { w.gap.max(1) } else { 1 };
                args.push(Arg { text, gap });
            }
        }
        let Some(name) = args.first().map(|a| a.text.clone()) else {
            for (name, value) in &assigns {
                if !self.vars.set(name, value) {
                    return Err(Stop(FAILED));
                }
            }
            return Ok(Started::Nothing);
        };
        if let Some(f) = builtin::find(&name) {
            return Ok(Started::Builtin(f, args, assigns));
        }
        let old = set_env(&assigns);
        let started = self.spawn(&name, &args);
        restore_env(old);
        match started {
            Ok(child) => Ok(Started::Program(child)),
            Err(e) => {
                let mut out = Out::err();
                match e.raw_os_error().unwrap_or(0) {
                    sys::E_NOEXEC => out.b(b"sh: not a program: ").b(&name),
                    sys::E_NOENT
                    | sys::E_NOTDIR
                    | sys::E_NOFS
                    | sys::E_NOPROC
                    | sys::E_NAMETOOLONG => out.b(b"sh: no such program: ").b(&name),
                    sys::E_2BIG => out.b(b"sh: the environment is too large for ").b(&name),
                    code => out.b(b"sh: cannot start it: ").n(code),
                };
                out.nl();
                Err(Stop(if e.raw_os_error() == Some(sys::E_NOEXEC) { NOT_STARTED } else { NOT_FOUND }))
            }
        }
    }

    /// Start program `name`: one of the image's, a path, or a file in
    /// one of $PATH's directories, the first that has it.
    fn spawn(&self, name: &[u8], args: &[Arg]) -> io::Result<Child> {
        if let Some(&(_, number)) = PROGRAMS.iter().find(|&&(p, _)| p == name) {
            return process::spawn_image(number);
        }
        let mut block = Vec::new();
        for a in args {
            block.extend_from_slice(&a.text);
            block.push(0);
        }
        if name.contains(&b'/') {
            return process::spawn_file(name, &block);
        }
        let none = io::Error::from_raw(sys::E_NOENT);
        let path = self.vars.get(b"PATH").unwrap_or(crate::vars::PATH);
        let mut last = none;
        for dir in path.split(|&c| c == b':') {
            let mut file = if dir.is_empty() { b".".to_vec() } else { dir.to_vec() };
            file.push(b'/');
            file.extend_from_slice(name);
            match process::spawn_file(&file, &block) {
                Ok(child) => return Ok(child),
                Err(e) => match e.raw_os_error() {
                    // Not in this one: try the next.
                    Some(sys::E_NOENT | sys::E_NOTDIR | sys::E_NAMETOOLONG) => last = e,
                    _ => return Err(e),
                },
            }
        }
        Err(last)
    }

    /// Keep the shell's standard input and output aside, out of
    /// children, the first time a line changes them.
    fn save(&mut self) {
        if !self.runner.saved {
            self.runner.saved = true;
            park(sys::STDIN, SAVE_IN);
            park(sys::STDOUT, SAVE_OUT);
        }
    }

    /// Put back what the line changed, close whatever a pipeline that
    /// stopped partway left open, so that its programs see their pipes
    /// end, and wait for the programs, in order: the last one's status.
    fn finish(&mut self) -> i32 {
        if core::mem::replace(&mut self.runner.saved, false) {
            restore(sys::STDIN, SAVE_IN);
            restore(sys::STDOUT, SAVE_OUT);
            for fd in sys::STDERR + 1..SAVE_IN {
                fs::close(fd);
            }
        }
        let mut status = self.status;
        let mut children = core::mem::take(&mut self.runner.children);
        let last = children.len().saturating_sub(1);
        for (k, child) in children.iter_mut().enumerate() {
            if let Some(mut child) = child.take() {
                let s = reap(&mut child);
                if k == last {
                    status = s;
                }
            }
        }
        self.runner.children = children;
        status
    }
}

/// Put assignments in the environment: what each name had, to go back.
fn set_env(assigns: &[(Vec<u8>, Vec<u8>)]) -> Vec<(Vec<u8>, Option<Vec<u8>>)> {
    let mut old = Vec::new();
    for (name, value) in assigns {
        old.push((name.clone(), env::var_bytes(name)));
        if let Err(e) = env::set_var(name, value) {
            fail(name, &e);
        }
    }
    old
}

/// Take back what `set_env` did, last first.
fn restore_env(old: Vec<(Vec<u8>, Option<Vec<u8>>)>) {
    for (name, value) in old.into_iter().rev() {
        let _ = match value {
            Some(v) => env::set_var(&name, &v),
            None => env::remove_var(&name),
        };
    }
}

fn say<T>(what: &[u8]) -> Result<T, Stop> {
    Out::err().b(what).nl();
    Err(Stop(FAILED))
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
/// since it is about the program, not its output. Its status.
fn reap(child: &mut Child) -> i32 {
    let _ = console::set_foreground(Some(child.id()));
    let status = child.wait();
    // The console is the shell's again before another program can have
    // this one's number.
    let _ = console::set_foreground(None);
    let Ok(status) = status else { return FAILED };
    let mut out = Out::err();
    if let Some(code) = status.code() {
        if code != 0 {
            out.b(b"sh: exit ").n(code).nl();
        }
        return code;
    }
    if let Some(cause) = status.fault() {
        out.b(b"sh: fault ").n(cause).nl();
        return 255;
    }
    let sig = status.signal().unwrap_or(sys::SIGKILL);
    if sig != sys::SIGPIPE {
        // A writer whose reader left: as Unix shells, nothing to say.
        out.b(b"sh: killed").nl();
    }
    128 + sig
}
