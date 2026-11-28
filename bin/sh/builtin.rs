//! The built-ins: exit, and ls, cat, write, rm, mkdir, rmdir, cd and pwd,
//! which use the filesystem through the file server. Each prints to
//! descriptors 1 and 2 as they are, so redirections and pipes reach it.

use trystd::fs::{self, File, OpenOptions};
use trystd::prelude::*;
use trystd::sys;

use crate::lex::Lexed;
use crate::out::{Out, fd_file};
use crate::run::Words;
use crate::{LINE_MAX, fail};

pub type Builtin = fn(&Lexed, &Words);

/// Each built-in, by name, in the order Tab lists them.
pub const BUILTINS: &[(&[u8], Builtin)] = &[
    (b"exit", exit),
    (b"ls", ls),
    (b"cat", cat),
    (b"write", write),
    (b"rm", rm),
    (b"mkdir", mkdir),
    (b"rmdir", rmdir),
    (b"cd", cd),
    (b"pwd", pwd),
];

/// Trytes cat reads at a time.
const BUF_MAX: usize = 243;
const NAME: usize = sys::NAME_MAX as usize;

pub fn find(name: &[u8]) -> Option<Builtin> {
    BUILTINS.iter().find(|&&(n, _)| n == name).map(|&(_, f)| f)
}

fn exit(_: &Lexed, _: &Words) {
    process::exit(0)
}

/// The built-in's first argument, the file it is about, or "which file?".
fn name_arg<'a>(lx: &'a Lexed, w: &Words) -> Option<&'a [u8]> {
    let name = w.get(lx, 1);
    if name.is_none() {
        Out::err().b(b"sh: which file?").nl();
    }
    name
}

/// ls [DIR]: each entry of DIR, or of the current directory, but those
/// whose names start with a dot: a file's size and name, a directory's
/// name and a slash. With an option first it is /bin/ls instead
/// (run.rs).
fn ls(lx: &Lexed, w: &Words) {
    let dir = w.get(lx, 1).unwrap_or(b".");
    let d = match File::open(dir) {
        Ok(d) => d,
        Err(e) => return fail(dir, &e),
    };
    let mut path = [0u8; LINE_MAX + NAME + 2];
    path[..dir.len()].copy_from_slice(dir);
    path[dir.len()] = b'/';
    let at = dir.len() + 1;
    let mut out = Out::new(1);
    let mut buf = [0u8; NAME + 1];
    loop {
        let name = match d.read_name(&mut buf) {
            Ok(Some(name)) => name,
            Ok(None) => return,
            Err(e) => return fail(dir, &e),
        };
        if name.first() == Some(&b'.') {
            continue; // hidden, as ls hides them
        }
        path[at..at + name.len()].copy_from_slice(name);
        let path = &path[..at + name.len()];
        let meta = match fs::metadata(path) {
            Ok(m) => m,
            Err(e) => return fail(path, &e),
        };
        if meta.is_dir() {
            out.b(name).c(b'/');
        } else {
            out.n(meta.len() as i32).c(b' ').b(name);
        }
        out.nl();
    }
}

/// cat [PATH]: print a file, or standard input to its end.
fn cat(lx: &Lexed, w: &Words) {
    let (name, r) = match w.get(lx, 1) {
        None => (&b"standard input"[..], copy_out(&mut fd_file(0))),
        Some(name) => (name, File::open(name).and_then(|mut f| copy_out(&mut f))),
    };
    if let Err(e) = r {
        fail(name, &e);
    }
}

/// Copy `from` to standard output, to its end or until nobody reads.
fn copy_out(from: &mut File) -> io::Result<()> {
    let mut buf = [0u8; BUF_MAX];
    loop {
        let n = from.read(&mut buf)?;
        if n == 0 || fd_file(1).write_all(&buf[..n]).is_err() {
            return Ok(());
        }
    }
}

/// write PATH TEXT: make PATH hold the rest of the line and a newline,
/// replacing what it held. The text keeps the spaces typed between its
/// words.
fn write(lx: &Lexed, w: &Words) {
    let Some(name) = name_arg(lx, w) else { return };
    let mut text = [0u8; LINE_MAX + 1];
    let mut n = 0;
    for k in 2..w.n {
        if k > 2 {
            let gap = lx.tok(w.at(k)).gap as usize;
            text[n..n + gap].fill(b' ');
            n += gap;
        }
        let word = lx.word(w.at(k));
        text[n..n + word.len()].copy_from_slice(word);
        n += word.len();
    }
    text[n] = b'\n';
    let r = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(name)
        .and_then(|mut f| f.write_all(&text[..n + 1]));
    if let Err(e) = r {
        fail(name, &e);
    }
}

fn path_call(lx: &Lexed, w: &Words, call: fn(&[u8]) -> io::Result<()>) {
    if let Some(name) = name_arg(lx, w) {
        if let Err(e) = call(name) {
            fail(name, &e);
        }
    }
}

fn rm(lx: &Lexed, w: &Words) {
    path_call(lx, w, |p| fs::remove_file(p))
}

fn mkdir(lx: &Lexed, w: &Words) {
    path_call(lx, w, |p| fs::create_dir(p))
}

fn rmdir(lx: &Lexed, w: &Words) {
    path_call(lx, w, |p| fs::remove_dir(p))
}

/// cd [DIR]: make DIR the current directory, or / with none; programs
/// the shell starts begin in it.
fn cd(lx: &Lexed, w: &Words) {
    let dir = w.get(lx, 1).unwrap_or(b"/");
    if let Err(e) = env::set_current_dir(dir) {
        fail(dir, &e);
    }
}

/// pwd: the current directory's path.
fn pwd(_: &Lexed, _: &Words) {
    let mut buf = [0u8; sys::PATH_MAX as usize + 1];
    match env::current_dir_in(&mut buf) {
        Ok(path) => Out::new(1).b(path).nl(),
        Err(e) => fail(b".", &e),
    }
}
