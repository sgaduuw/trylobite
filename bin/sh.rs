//! sh: the shell, which init (user/init.s) starts from the disk once the
//! servers are up. It reads a line, runs the program its first word
//! names, waits for it, and says how it ended if not with code 0.
//!
//! Some words are built in (sh/builtin.rs): exit; ls, cat, write, rm,
//! mkdir, rmdir, cd and pwd, which use the filesystem through the file
//! server; and export, unset, env and set. pingpong is a program of the
//! kernel image, started by number. Any other word names a program file:
//! a path if it has a slash, else the first file of that name in the
//! directories $PATH lists, and gets the line's words as its arguments,
//! the command first. The shell stops at the end of input.
//!
//! Variables (sh/vars.rs) are the shell's, or exported: those are the
//! environment of the programs it starts, which it starts with its own
//! environment's, and PATH and HOME. $NAME in a word stands for a value
//! (sh/expand.rs), as do $? (the last command's status) and $$.
//!
//! The line is edited as typed (sh/edit.rs): the cursor keys, the Ctrl
//! keys of a Unix shell, a history on up and down, and Tab completion.
//! Quotes make characters themselves, as in a Unix shell (sh/expand.rs):
//! 'a b' and "a b" are one word holding a space, \ makes the next
//! character itself, and a quoted |, < or > neither pipes nor
//! redirects. A word starting with < or > redirects standard input or
//! output, and | joins commands into a pipeline (sh/run.rs).
//!
//! The console is the console server's. A shell that has no standard
//! input (as init starts it) opens the console as its standard input,
//! output and error, which the programs it starts inherit; one started
//! with them (sh from the shell) keeps its own. It gives each program it
//! waits for the console's foreground, for Ctrl-C, if its standard input
//! is the console (a remote shell's is a connection, bin/telnetd); at
//! the prompt Ctrl-C drops the line. Its own complaints go to standard error, so they
//! reach the console whatever a command redirects. It catches SIGPIPE,
//! so that a built-in writing to a pipe whose reader has gone carries on,
//! while the programs it starts have SIGPIPE's default.
//!
//! Lexing, expanding, running and editing are apart, so that a
//! scripting language can sit between the lexer and the runner. Words,
//! arguments and variables are on the heap.
#![no_std]

use core::sync::atomic::{AtomicBool, Ordering};
use trystd::prelude::*;
use trystd::{console, fs, signal, sys};

#[path = "sh/builtin.rs"]
mod builtin;
#[path = "sh/edit.rs"]
mod edit;
#[path = "sh/expand.rs"]
mod expand;
#[path = "sh/lex.rs"]
mod lex;
#[path = "sh/out.rs"]
mod out;
#[path = "sh/run.rs"]
mod run;
#[path = "sh/vars.rs"]
mod vars;

use edit::{Editor, Got};
use out::Out;

trystd::main!(sh);

/// Characters kept from a typed line.
pub const LINE_MAX: usize = 240;
pub const PROMPT: &[u8] = b"$ ";

/// Whether standard input is the console, as the shell started.
static ON_CONSOLE: AtomicBool = AtomicBool::new(false);

pub fn on_console() -> bool {
    ON_CONSOLE.load(Ordering::Relaxed)
}

/// The editor's history is a kilotryte: in the image, not on the stack.
static mut EDITOR: Editor = Editor::new();

fn sh() -> i32 {
    let _ = signal::signal(signal::SIGPIPE, signal::Handler::Catch(|_| {}));
    if !fs::is_open(sys::STDIN) {
        // Started by init: the console's first descriptor comes as 0.
        if let Ok(con) = console::open() {
            let con = con.into_raw();
            let _ = fs::dup2(con, sys::STDOUT);
            let _ = fs::dup2(con, sys::STDERR);
        }
    }
    ON_CONSOLE.store(io::is_terminal(sys::STDIN), Ordering::Relaxed);
    // Only this function touches it, and only from here on.
    let editor = unsafe { &mut *core::ptr::addr_of_mut!(EDITOR) };
    let mut sh = Shell { vars: vars::Vars::import(), status: 0, runner: run::Runner::new() };
    loop {
        Out::new(sys::STDOUT).b(PROMPT).flush();
        match editor.read() {
            Got::End => return 0,
            Got::Cancel => continue,
            Got::Line => {}
        }
        sh.line(editor.line());
    }
}

/// The shell's state: its variables, the last command's status, and
/// what the runner keeps.
pub struct Shell {
    pub vars: vars::Vars,
    /// $?: the last command's status.
    pub status: i32,
    pub runner: run::Runner,
}

impl Shell {
    /// Run a line.
    fn line(&mut self, line: &[u8]) {
        let toks = match lex::lex(line) {
            Ok(toks) => toks,
            Err(lex::Unclosed) => {
                Out::err().b(b"sh: a quote is not closed").nl();
                self.status = run::FAILED;
                return;
            }
        };
        match run::parse(&toks) {
            Ok(cmds) if cmds.is_empty() => {}
            Ok(cmds) => self.status = self.pipeline(&cmds),
            Err(said) => {
                Out::err().b(said).nl();
                self.status = run::FAILED;
            }
        }
    }
}

/// Say why a call about `path` failed, as Unix tools do, in the words
/// the shell has always used: the status that leaves, 1.
pub fn fail(path: &[u8], e: &io::Error) -> i32 {
    let mut out = Out::err();
    out.b(b"sh: ").b(path).b(b": ");
    let code = e.raw_os_error().unwrap_or(0);
    let said: &[u8] = match code {
        sys::E_NOENT => b"no such file or directory",
        sys::E_NOTDIR => b"not a directory",
        sys::E_ISDIR => b"is a directory",
        sys::E_NOFS | sys::E_NOPROC => b"no filesystem on the disk",
        sys::E_NAMETOOLONG => b"name too long",
        sys::E_EXIST => b"file exists",
        sys::E_NOSPC => b"no space left",
        sys::E_NOTEMPTY => b"directory not empty",
        sys::E_BUSY => b"busy",
        sys::E_INVAL => b"invalid argument",
        sys::E_2BIG => b"the environment is full",
        _ => {
            out.b(b"error ").n(code).nl();
            return 1;
        }
    };
    out.b(said).nl();
    1
}
