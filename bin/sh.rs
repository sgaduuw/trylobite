//! sh: the shell, which init (user/init.s) starts from the disk once the
//! servers are up. With no arguments it reads lines at a prompt and runs
//! them; `sh FILE [ARG...]` runs a script, and `sh -c COMMANDS [NAME
//! [ARG...]]` a string. A line typed that does not finish its command
//! (an if without its fi, a quote not closed, a | at the end) goes on at
//! a "> " prompt.
//!
//! The language is POSIX sh's, kept reasonable (sh/lex.rs, sh/parse.rs,
//! sh/run.rs): pipelines, lists with ; && || and & (background jobs, of
//! programs only), if, while, until, for, case, { } and ( ) groups,
//! functions, redirections < > >> and N>&M, and comments. Words expand
//! (sh/expand.rs): quotes, $NAME and ${NAME...}, the positional and
//! special parameters, $(...), $((...)) (sh/arith.rs), ~, and patterns
//! (sh/glob.rs). Variables (sh/vars.rs) are the shell's, or exported:
//! the environment of the programs it starts.
//!
//! Some words are built in (sh/builtin.rs): exit; ls, cat, write, rm,
//! mkdir, rmdir, cd and pwd, which use the filesystem through the file
//! server; export, unset, env and set; true, false, :, test and [, read,
//! shift, break, continue, return, wait, jobs, . and source, eval.
//! pingpong is a program of the kernel image. Any other word names a
//! program file: a path if it has a slash, else the first file of that
//! name in the directories $PATH lists; a file starting with #! runs
//! the program its first line names.
//!
//! The line is edited as typed (sh/edit.rs): the cursor keys, the Ctrl
//! keys of a Unix shell, a history on up and down, and Tab completion.
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
//! It moves to a large stack from the heap as it starts, since a
//! script nests deeper than a program's half page of stack holds.
#![no_std]

use core::sync::atomic::{AtomicBool, Ordering};
use trystd::prelude::*;
use trystd::{console, fs, process, signal, sys, thread};

#[path = "sh/arith.rs"]
mod arith;
#[path = "sh/builtin.rs"]
mod builtin;
#[path = "sh/edit.rs"]
mod edit;
#[path = "sh/expand.rs"]
mod expand;
#[path = "sh/glob.rs"]
mod glob;
#[path = "sh/lex.rs"]
mod lex;
#[path = "sh/out.rs"]
mod out;
#[path = "sh/parse.rs"]
mod parse;
#[path = "sh/run.rs"]
mod run;
#[path = "sh/vars.rs"]
mod vars;

use alloc::rc::Rc;
use edit::{Editor, Got};
use out::Out;
use parse::{Error, Parser};

extern crate alloc;

trystd::main!(sh);

/// Characters kept from a typed line.
pub const LINE_MAX: usize = 240;
pub const PROMPT: &[u8] = b"$ ";
/// The prompt for a line that goes on with what came before.
pub const PROMPT2: &[u8] = b"> ";
/// The status of a script with a syntax error, and of a usage error.
pub const SYNTAX: i32 = 2;

/// Whether standard input is the console, as the shell started.
static ON_CONSOLE: AtomicBool = AtomicBool::new(false);

pub fn on_console() -> bool {
    ON_CONSOLE.load(Ordering::Relaxed)
}

/// The editor's history is a kilotryte: in the image, not on the stack.
static mut EDITOR: Editor = Editor::new();

/// The stack the shell runs on, in trytes: a running script nests
/// lists, functions and substitutions deeper than the half page below a
/// program's image holds, so the shell moves to a stack from the heap.
const STACK: usize = 177147;

fn sh() -> i32 {
    thread::with_stack(STACK, shell)
}

fn shell() -> i32 {
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
    let args: Vec<&[u8]> = env::args_bytes().collect();
    let mut sh = Shell::new(args.first().copied().unwrap_or(b"sh"));
    match args.get(1).copied() {
        // sh -c COMMANDS [NAME [ARG...]]
        Some(b"-c") => {
            let Some(&text) = args.get(2) else {
                Out::err().b(b"sh: -c needs commands").nl();
                return SYNTAX;
            };
            if let Some(&name) = args.get(3) {
                sh.arg0 = name.to_vec();
            }
            sh.params = args.iter().skip(4).map(|a| a.to_vec()).collect();
            sh.source(text, b"-c")
        }
        // sh FILE [ARG...]
        Some(file) => {
            sh.arg0 = file.to_vec();
            sh.params = args[2..].iter().map(|a| a.to_vec()).collect();
            match fs::read(file) {
                Ok(text) => sh.source(&text, file),
                Err(e) => {
                    fail(file, &e);
                    run::NOT_FOUND
                }
            }
        }
        None => sh.interactive(),
    }
}

/// The shell's state.
pub struct Shell {
    pub vars: vars::Vars,
    /// $?: the last command's status.
    pub status: i32,
    /// $0, and $1 on.
    pub arg0: Vec<u8>,
    pub params: Vec<Vec<u8>>,
    /// $!: the last background job's last program.
    pub last_bg: Option<u32>,
    pub functions: Vec<(Vec<u8>, Rc<parse::Command>)>,
    pub jobs: Vec<run::BgJob>,
    /// A break, continue or return under way.
    pub flow: Option<run::Flow>,
    /// Reading lines typed at the prompt, not a script.
    pub interactive: bool,
    /// More than 0 while a status runs that is tested (an if's
    /// condition, a side of && or ||): programs' exits go unsaid.
    pub testing: u32,
    /// Functions called and not yet returned.
    pub depth: u32,
    /// Descriptors redirected, and the spare one keeping what each held
    /// (sh/run.rs).
    pub saves: Vec<(i32, Option<i32>)>,
    /// Command substitutions so far, to name their files.
    pub substs: u32,
}

impl Shell {
    fn new(arg0: &[u8]) -> Shell {
        Shell {
            vars: vars::Vars::import(),
            status: 0,
            arg0: arg0.to_vec(),
            params: Vec::new(),
            last_bg: None,
            functions: Vec::new(),
            jobs: Vec::new(),
            flow: None,
            interactive: false,
            testing: 0,
            depth: 0,
            saves: Vec::new(),
            substs: 0,
        }
    }

    /// Read lines at the prompt and run them, until the end of input.
    fn interactive(&mut self) -> i32 {
        self.interactive = true;
        // Only this function touches it, and only from here on.
        let editor = unsafe { &mut *core::ptr::addr_of_mut!(EDITOR) };
        let mut text: Vec<u8> = Vec::new();
        loop {
            if text.is_empty() {
                self.check_jobs();
            }
            let prompt = if text.is_empty() { PROMPT } else { PROMPT2 };
            Out::new(sys::STDOUT).b(prompt).flush();
            match editor.read() {
                Got::End => {
                    if !text.is_empty() {
                        Out::err().b(b"sh: the input ends inside a command").nl();
                    }
                    return self.status_at_end();
                }
                Got::Cancel => {
                    text.clear();
                    continue;
                }
                Got::Line => {}
            }
            text.extend_from_slice(editor.line());
            text.push(b'\n');
            // A line ending in an odd number of \ goes on to the next.
            let slashes = editor.line().iter().rev().take_while(|&&c| c == b'\\').count();
            if slashes % 2 == 1 {
                continue;
            }
            let Ok(toks) = lex::lex(&text) else {
                continue; // a quote goes on to the next line
            };
            let mut parser = Parser::new(toks);
            let mut lists = Vec::new();
            let mut more = false;
            loop {
                match parser.next_line() {
                    Ok(Some(list)) => lists.push(list),
                    Ok(None) => break,
                    Err(Error::Incomplete) => {
                        more = true;
                        break;
                    }
                    Err(Error::Syntax(_, said)) => {
                        Out::err().b(&said).nl();
                        self.status = SYNTAX;
                        lists.clear();
                        break;
                    }
                }
            }
            if more {
                continue; // the command goes on to the next line
            }
            text.clear();
            for list in &lists {
                self.run_list(list);
                self.flow = None;
            }
        }
    }

    /// At the end of input: 0, as the shell always has.
    fn status_at_end(&self) -> i32 {
        0
    }

    /// Run a script's text, a command line at a time: its last status, or
    /// SYNTAX at an error, said with the line it is on.
    pub fn source(&mut self, text: &[u8], name: &[u8]) -> i32 {
        if self.depth >= run::MAX_DEPTH {
            Out::err().b(b"sh: ").b(name).b(b": nested too deep").nl();
            return run::FAILED;
        }
        self.depth += 1;
        let status = self.source_in(text, name);
        self.depth -= 1;
        status
    }

    fn source_in(&mut self, text: &[u8], name: &[u8]) -> i32 {
        let toks = match lex::lex(text) {
            Ok(toks) => toks,
            Err(lex::Unclosed) => {
                Out::err().b(b"sh: ").b(name).b(b": a quote or bracket is not closed").nl();
                return SYNTAX;
            }
        };
        let mut parser = Parser::new(toks);
        loop {
            match parser.next_line() {
                Ok(Some(list)) => {
                    self.run_list(&list);
                    if self.flow == Some(run::Flow::Return) {
                        break; // return in a sourced file ends it
                    }
                    self.flow = None;
                }
                Ok(None) => return self.status,
                Err(Error::Incomplete) => {
                    Out::err().b(b"sh: ").b(name).b(b": the file ends inside a command").nl();
                    return SYNTAX;
                }
                Err(Error::Syntax(line, said)) => {
                    let mut out = Out::err();
                    out.b(b"sh: ").b(name).b(b": line ").n(line as i32).b(b": ");
                    out.b(said.strip_prefix(b"sh: ").unwrap_or(&said)).nl();
                    return SYNTAX;
                }
            }
        }
        self.status
    }

    /// $(LIST): what LIST prints, less the newlines it ends with. Its
    /// standard output goes to a file meanwhile, which the shell reads
    /// back, so that it can run anything, built-ins and all, with no
    /// fork and no pipe to fill.
    pub fn substitute(&mut self, text: &[u8]) -> Vec<u8> {
        self.substs += 1;
        let dir: &[u8] = if fs::metadata("/tmp").is_ok_and(|m| m.is_dir()) { b"/tmp/" } else { b"/" };
        let mut path = dir.to_vec();
        path.extend_from_slice(b".sh");
        path.extend_from_slice(&expand::number(process::id() as i32));
        path.push(b'.');
        path.extend_from_slice(&expand::number(self.substs as i32));
        let mark = self.saves.len();
        let file = match fs::File::create(&path) {
            Ok(f) => f.into_fd(),
            Err(e) => {
                fail(&path, &e);
                return Vec::new();
            }
        };
        let redirected = self.save_fd(sys::STDOUT).is_ok();
        if redirected {
            let _ = fs::dup2(file.raw(), sys::STDOUT);
        }
        drop(file);
        if redirected {
            let interactive = core::mem::replace(&mut self.interactive, false);
            self.source(text, b"$(...)");
            self.interactive = interactive;
            self.flow = None;
        }
        self.restore_to(mark);
        let mut out = fs::read(&path).unwrap_or_default();
        let _ = fs::remove_file(&path);
        while out.last() == Some(&b'\n') {
            out.pop();
        }
        out
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
