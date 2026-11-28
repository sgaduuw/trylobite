//! The built-ins: exit; ls, cat, write, rm, mkdir, rmdir, cd and pwd,
//! which use the filesystem through the file server; and export, unset,
//! env and set for variables. Each prints to descriptors 1 and 2 as they
//! are, so redirections and pipes reach it, and gives a status: 0 when
//! it did what it was asked, 1 when not, having said why, as Unix's.

use trystd::fs::{self, File, OpenOptions};
use trystd::prelude::*;
use trystd::sys;

use crate::expand::Arg;
use crate::out::{Out, fd_file};
use crate::vars::is_name;
use crate::{Shell, fail};

pub type Builtin = fn(&mut Shell, &[Arg]) -> i32;

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
    (b"export", export),
    (b"unset", unset),
    (b"env", env),
    (b"set", set),
];

/// Trytes cat reads at a time.
const BUF_MAX: usize = 243;

pub fn find(name: &[u8]) -> Option<Builtin> {
    BUILTINS.iter().find(|&&(n, _)| n == name).map(|&(_, f)| f)
}

/// Argument `k`, if there is one.
fn arg(args: &[Arg], k: usize) -> Option<&[u8]> {
    args.get(k).map(|a| &a.text[..])
}

/// exit [CODE]: end the shell, with CODE or the last command's status.
fn exit(sh: &mut Shell, args: &[Arg]) -> i32 {
    let code = match arg(args, 1) {
        None => sh.status,
        Some(n) => match parse_number(n) {
            Some(n) => n,
            None => {
                Out::err().b(b"sh: exit: not a number: ").b(n).nl();
                return 2;
            }
        },
    };
    process::exit(code)
}

/// A decimal number, perhaps negative.
pub fn parse_number(s: &[u8]) -> Option<i32> {
    let (neg, digits) = match s.strip_prefix(b"-") {
        Some(d) => (true, d),
        None => (false, s),
    };
    if digits.is_empty() || digits.len() > 9 || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let n = digits.iter().fold(0i32, |n, &c| n * 10 + (c - b'0') as i32);
    Some(if neg { -n } else { n })
}

/// The built-in's first argument, the file it is about, or "which file?".
fn name_arg(args: &[Arg]) -> Option<&[u8]> {
    let name = arg(args, 1);
    if name.is_none() {
        Out::err().b(b"sh: which file?").nl();
    }
    name
}

/// ls [DIR]: each entry of DIR, or of the current directory, but those
/// whose names start with a dot: a file's size and name, a directory's
/// name and a slash.
fn ls(_: &mut Shell, args: &[Arg]) -> i32 {
    let dir = arg(args, 1).unwrap_or(b".");
    let d = match File::open(dir) {
        Ok(d) => d,
        Err(e) => return fail(dir, &e),
    };
    let mut path = dir.to_vec();
    path.push(b'/');
    let at = path.len();
    let mut out = Out::new(1);
    let mut buf = [0u8; sys::NAME_MAX as usize + 1];
    loop {
        let name = match d.read_name(&mut buf) {
            Ok(Some(name)) => name,
            Ok(None) => return 0,
            Err(e) => return fail(dir, &e),
        };
        if name.first() == Some(&b'.') {
            continue; // hidden, as ls hides them
        }
        path.truncate(at);
        path.extend_from_slice(name);
        let meta = match fs::metadata(&path) {
            Ok(m) => m,
            Err(e) => return fail(&path, &e),
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
fn cat(_: &mut Shell, args: &[Arg]) -> i32 {
    let (name, r) = match arg(args, 1) {
        None => (&b"standard input"[..], copy_out(&mut fd_file(0))),
        Some(name) => (name, File::open(name).and_then(|mut f| copy_out(&mut f))),
    };
    match r {
        Ok(()) => 0,
        Err(e) => fail(name, &e),
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
fn write(_: &mut Shell, args: &[Arg]) -> i32 {
    let Some(name) = name_arg(args) else { return 1 };
    let mut text = Vec::new();
    for (k, a) in args.iter().enumerate().skip(2) {
        if k > 2 {
            text.resize(text.len() + a.gap as usize, b' ');
        }
        text.extend_from_slice(&a.text);
    }
    text.push(b'\n');
    let r = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(name)
        .and_then(|mut f| f.write_all(&text));
    match r {
        Ok(()) => 0,
        Err(e) => fail(name, &e),
    }
}

fn path_call(args: &[Arg], call: fn(&[u8]) -> io::Result<()>) -> i32 {
    let Some(name) = name_arg(args) else { return 1 };
    match call(name) {
        Ok(()) => 0,
        Err(e) => fail(name, &e),
    }
}

fn rm(_: &mut Shell, args: &[Arg]) -> i32 {
    path_call(args, |p| fs::remove_file(p))
}

fn mkdir(_: &mut Shell, args: &[Arg]) -> i32 {
    path_call(args, |p| fs::create_dir(p))
}

fn rmdir(_: &mut Shell, args: &[Arg]) -> i32 {
    path_call(args, |p| fs::remove_dir(p))
}

/// cd [DIR]: make DIR the current directory, or $HOME (else /) with
/// none; programs the shell starts begin in it.
fn cd(sh: &mut Shell, args: &[Arg]) -> i32 {
    let dir = match arg(args, 1) {
        Some(dir) => dir.to_vec(),
        None => sh.vars.get(b"HOME").unwrap_or(b"/").to_vec(),
    };
    match env::set_current_dir(&dir) {
        Ok(()) => 0,
        Err(e) => fail(&dir, &e),
    }
}

/// pwd: the current directory's path.
fn pwd(_: &mut Shell, _: &[Arg]) -> i32 {
    let mut buf = [0u8; sys::PATH_MAX as usize + 1];
    match env::current_dir_in(&mut buf) {
        Ok(path) => {
            Out::new(1).b(path).nl();
            0
        }
        Err(e) => fail(b".", &e),
    }
}

/// export [NAME[=VALUE]...]: put each NAME in the environment of the
/// programs the shell starts, giving it VALUE first if there is one;
/// with none, list what is exported, as `export NAME=VALUE` lines.
fn export(sh: &mut Shell, args: &[Arg]) -> i32 {
    if args.len() == 1 {
        let mut out = Out::new(1);
        for v in sh.vars.list.iter().filter(|v| v.exported) {
            out.b(b"export ").b(&v.name).c(b'=');
            quoted(&mut out, &v.value);
            out.nl();
        }
        return 0;
    }
    let mut status = 0;
    for a in &args[1..] {
        let (name, value) = match a.text.iter().position(|&c| c == b'=') {
            Some(k) => (&a.text[..k], Some(&a.text[k + 1..])),
            None => (&a.text[..], None),
        };
        if !is_name(name) {
            Out::err().b(b"sh: export: not a name: ").b(name).nl();
            status = 1;
            continue;
        }
        let ok = sh.vars.export(name) && value.is_none_or(|v| sh.vars.set(name, v));
        if !ok {
            status = 1;
        }
    }
    status
}

/// unset NAME...: forget each variable, and take it out of the
/// environment.
fn unset(sh: &mut Shell, args: &[Arg]) -> i32 {
    for a in &args[1..] {
        sh.vars.unset(&a.text);
    }
    0
}

/// env: the environment the shell's programs get, a NAME=VALUE line
/// each.
fn env(_: &mut Shell, _: &[Arg]) -> i32 {
    let mut out = Out::new(1);
    for (name, value) in env::vars_bytes() {
        out.b(&name).c(b'=').b(&value).nl();
    }
    0
}

/// set: every variable, exported or not, as NAME=VALUE lines that the
/// shell would read back.
fn set(sh: &mut Shell, _: &[Arg]) -> i32 {
    let mut out = Out::new(1);
    for v in &sh.vars.list {
        out.b(&v.name).c(b'=');
        quoted(&mut out, &v.value);
        out.nl();
    }
    0
}

/// `value` as the shell reads it back: as it is if it is plain, else in
/// single quotes.
fn quoted(out: &mut Out, value: &[u8]) {
    let plain = !value.is_empty()
        && value.iter().all(|&c| c.is_ascii_alphanumeric() || b"/.-_:,+@%".contains(&c));
    if plain {
        out.b(value);
        return;
    }
    out.c(b'\'');
    for &c in value {
        if c == b'\'' {
            out.b(b"'\\''");
        } else {
            out.c(c);
        }
    }
    out.c(b'\'');
}
