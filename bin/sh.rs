//! sh: the shell, which init (user/init.s) starts from the disk once the
//! servers are up. It reads a line, runs the program its first word
//! names, waits for it, and says how it ended if not with code 0.
//!
//! Some words are built in (sh/builtin.rs): exit, and ls, cat, write,
//! rm, mkdir, rmdir, cd and pwd, which use the filesystem through the
//! file server. pingpong is a program of the kernel image, started by
//! number. Any other word names a program file: a path if it has a
//! slash, else a file in /bin, and gets the line's words as its
//! arguments, the command first. The shell stops at the end of input.
//!
//! The line is edited as typed (sh/edit.rs): the cursor keys, the Ctrl
//! keys of a Unix shell, a history on up and down, and Tab completion.
//! Quotes make characters themselves, as in a Unix shell (sh/lex.rs):
//! 'a b' and "a b" are one word holding a space, \ makes the next
//! character itself, and a quoted |, < or > neither pipes nor
//! redirects. A word starting with < or > redirects standard input or
//! output, and | joins commands into a pipeline (sh/run.rs).
//!
//! The console is the console server's. A shell that has no standard
//! input (as init starts it) opens the console as its standard input,
//! output and error, which the programs it starts inherit; one started
//! with them (sh from the shell) keeps its own. It gives each program it
//! waits for the console's foreground, for Ctrl-C; at the prompt Ctrl-C
//! drops the line. Its own complaints go to standard error, so they
//! reach the console whatever a command redirects. It catches SIGPIPE,
//! so that a built-in writing to a pipe whose reader has gone carries on,
//! while the programs it starts have SIGPIPE's default.
//!
//! It is written to grow into a scripting shell: lexing, running and
//! editing are apart, and nothing uses the heap, so it takes the five
//! pages of a program over half a page, and no sixth.
#![no_std]

use trystd::prelude::*;
use trystd::{console, fs, signal, sys};

#[path = "sh/builtin.rs"]
mod builtin;
#[path = "sh/edit.rs"]
mod edit;
#[path = "sh/lex.rs"]
mod lex;
#[path = "sh/out.rs"]
mod out;
#[path = "sh/run.rs"]
mod run;

use edit::{Editor, Got};
use lex::Lexed;
use out::Out;

trystd::main!(sh);

/// Characters kept from a line.
pub const LINE_MAX: usize = 60;
pub const PROMPT: &[u8] = b"$ ";

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
    // Only this function touches it, and only from here on.
    let editor = unsafe { &mut *core::ptr::addr_of_mut!(EDITOR) };
    let mut runner = run::Runner::new();
    loop {
        Out::new(sys::STDOUT).b(PROMPT).flush();
        match editor.read() {
            Got::End => return 0,
            Got::Cancel => continue,
            Got::Line => {}
        }
        match Lexed::lex(editor.line()) {
            Ok(lx) => runner.line(&lx),
            Err(lex::Unclosed) => Out::err().b(b"sh: a quote is not closed").nl(),
        }
    }
}

/// Say why a call about `path` failed, as Unix tools do, in the words
/// the shell has always used.
pub fn fail(path: &[u8], e: &io::Error) {
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
        _ => {
            out.b(b"error ").n(code).nl();
            return;
        }
    };
    out.b(said).nl();
}
