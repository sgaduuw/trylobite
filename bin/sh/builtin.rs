//! The built-ins: exit; ls, cat, write, rm, mkdir, rmdir, cd and pwd,
//! which use the filesystem through the file server; and export, unset,
//! env and set for variables. Each prints to descriptors 1 and 2 as they
//! are, so redirections and pipes reach it, and gives a status: 0 when
//! it did what it was asked, 1 when not, having said why, as Unix's.

use trystd::fs::{self, File, OpenOptions};
use trystd::prelude::*;
use trystd::{signal, sys};

use crate::expand::Arg;
use crate::run::{Flow, WaitFor};
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
    (b"true", true_),
    (b"false", false_),
    (b":", true_),
    (b"test", test),
    (b"[", test),
    (b"read", read),
    (b"shift", shift),
    (b"break", break_),
    (b"continue", continue_),
    (b"return", return_),
    (b"wait", wait),
    (b"jobs", jobs),
    (b"fg", fg),
    (b"bg", bg),
    (b"kill", kill),
    (b".", source),
    (b"source", source),
    (b"eval", eval),
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
/// At the prompt, with jobs stopped, it says so the first time instead;
/// exit again at once, and the shell ends (its stopped jobs are sent
/// SIGHUP and SIGCONT as they lose their parent).
fn exit(sh: &mut Shell, args: &[Arg]) -> i32 {
    if sh.interactive && sh.jobs.iter().any(|j| j.stopped) && sh.exit_warned != Some(sh.lines.wrapping_sub(1)) {
        Out::err().b(b"sh: there are stopped jobs").nl();
        sh.exit_warned = Some(sh.lines);
        return 1;
    }
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
    parse_number64(s).and_then(|n| i32::try_from(n).ok())
}

/// The same in 64 bits, perhaps after a +.
pub fn parse_number64(s: &[u8]) -> Option<i64> {
    let s = s.strip_prefix(b"+").unwrap_or(s);
    let (neg, digits) = match s.strip_prefix(b"-") {
        Some(d) => (true, d),
        None => (false, s),
    };
    if digits.is_empty() || digits.len() > 18 || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let n = digits.iter().fold(0i64, |n, &c| n * 10 + (c - b'0') as i64);
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

fn true_(_: &mut Shell, _: &[Arg]) -> i32 {
    0
}

fn false_(_: &mut Shell, _: &[Arg]) -> i32 {
    1
}

/// test EXPR, or [ EXPR ]: 0 if EXPR holds, 1 if not, 2 if it is not
/// an expression. -e -f -d -s FILE: it exists, is a file, a directory,
/// a file not empty; -z -n S: S is empty, not; S = T, S != T; N -eq M
/// and -ne -lt -le -gt -ge, numbers; ! EXPR; EXPR -a EXPR, EXPR -o EXPR;
/// a lone S: it is not empty.
fn test(_: &mut Shell, args: &[Arg]) -> i32 {
    let mut words: Vec<&[u8]> = args[1..].iter().map(|a| &a.text[..]).collect();
    if args[0].text == b"[" {
        if words.last() != Some(&&b"]"[..]) {
            Out::err().b(b"sh: [: no ] at the end").nl();
            return 2;
        }
        words.pop();
    }
    let mut t = Test { words: &words, at: 0, bad: false };
    let r = t.or();
    if t.bad || t.at != words.len() {
        Out::err().b(b"sh: test: not an expression").nl();
        return 2;
    }
    (!r) as i32
}

struct Test<'a> {
    words: &'a [&'a [u8]],
    at: usize,
    bad: bool,
}

impl<'a> Test<'a> {
    fn peek(&self, k: usize) -> Option<&'a [u8]> {
        self.words.get(self.at + k).copied()
    }

    fn or(&mut self) -> bool {
        let mut r = self.and();
        while self.peek(0) == Some(b"-o") {
            self.at += 1;
            r |= self.and();
        }
        r
    }

    fn and(&mut self) -> bool {
        let mut r = self.not();
        while self.peek(0) == Some(b"-a") {
            self.at += 1;
            r &= self.not();
        }
        r
    }

    fn not(&mut self) -> bool {
        if self.peek(0) == Some(b"!") && self.peek(1).is_some() {
            self.at += 1;
            return !self.not();
        }
        self.primary()
    }

    fn primary(&mut self) -> bool {
        let Some(a) = self.peek(0) else {
            return false; // nothing: false
        };
        // A binary operator between two words.
        if let (Some(op), Some(b)) = (self.peek(1), self.peek(2)) {
            let r = match op {
                b"=" | b"==" => Some(a == b),
                b"!=" => Some(a != b),
                b"-eq" | b"-ne" | b"-lt" | b"-le" | b"-gt" | b"-ge" => {
                    match (parse_number64(a.trim_ascii()), parse_number64(b.trim_ascii())) {
                        (Some(x), Some(y)) => Some(match op {
                            b"-eq" => x == y,
                            b"-ne" => x != y,
                            b"-lt" => x < y,
                            b"-le" => x <= y,
                            b"-gt" => x > y,
                            _ => x >= y,
                        }),
                        _ => {
                            Out::err().b(b"sh: test: not a number").nl();
                            self.bad = true;
                            Some(false)
                        }
                    }
                }
                _ => None,
            };
            if let Some(r) = r {
                self.at += 3;
                return r;
            }
        }
        if a.len() == 2 && a[0] == b'-' {
            if let Some(b) = self.peek(1) {
                let r = match a[1] {
                    b'z' => Some(b.is_empty()),
                    b'n' => Some(!b.is_empty()),
                    b'e' => Some(fs::metadata(b).is_ok()),
                    b'f' => Some(fs::metadata(b).is_ok_and(|m| m.is_file())),
                    b'd' => Some(fs::metadata(b).is_ok_and(|m| m.is_dir())),
                    b's' => Some(fs::metadata(b).is_ok_and(|m| m.len() > 0)),
                    _ => None,
                };
                if let Some(r) = r {
                    self.at += 2;
                    return r;
                }
            }
        }
        self.at += 1;
        !a.is_empty()
    }
}

/// read [-r] NAME...: a line of standard input, split at blanks into the
/// names, the last taking the rest; without -r, \ makes the next
/// character itself and joins a line to the next. 1 at the end of input
/// with nothing read. It reads a character at a time, so that what
/// follows the line is left for whoever reads next.
fn read(sh: &mut Shell, args: &[Arg]) -> i32 {
    let mut names: Vec<&[u8]> = args[1..].iter().map(|a| &a.text[..]).collect();
    let raw = names.first() == Some(&&b"-r"[..]);
    if raw {
        names.remove(0);
    }
    if names.is_empty() {
        names.push(b"REPLY");
    }
    // Each character, and whether \ made it itself.
    let mut line: Vec<(u8, bool)> = Vec::new();
    let mut got_any = false;
    let mut ended = false;
    let mut escaped = false;
    loop {
        let mut c = [0u8; 1];
        match fd_file(0).read(&mut c) {
            Ok(1) => {}
            _ => {
                ended = true;
                break;
            }
        }
        got_any = true;
        let c = c[0];
        if escaped {
            escaped = false;
            if c != b'\n' {
                line.push((c, true));
            }
            continue;
        }
        match c {
            b'\n' => break,
            b'\\' if !raw => escaped = true,
            _ => line.push((c, false)),
        }
    }
    let blank = |&(c, q): &(u8, bool)| !q && matches!(c, b' ' | b'\t');
    let mut rest = &line[..];
    for (k, name) in names.iter().enumerate() {
        while rest.first().is_some_and(blank) {
            rest = &rest[1..];
        }
        let value: Vec<u8> = if k + 1 == names.len() {
            let mut v = rest;
            while v.last().is_some_and(blank) {
                v = &v[..v.len() - 1];
            }
            rest = &[];
            v.iter().map(|&(c, _)| c).collect()
        } else {
            let n = rest.iter().position(blank).unwrap_or(rest.len());
            let v = rest[..n].iter().map(|&(c, _)| c).collect();
            rest = &rest[n..];
            v
        };
        if !is_name(name) {
            Out::err().b(b"sh: read: not a name: ").b(name).nl();
            return 2;
        }
        if !sh.vars.set(name, &value) {
            return 1;
        }
    }
    (ended && !(got_any && !line.is_empty())) as i32
}

/// shift [N]: drop the first N positional parameters (1).
fn shift(sh: &mut Shell, args: &[Arg]) -> i32 {
    let n = match count_arg(args, b"shift") {
        Some(n) => n as usize,
        None => return 2,
    };
    if n > sh.params.len() {
        Out::err().b(b"sh: shift: not that many parameters").nl();
        return 1;
    }
    sh.params.drain(..n);
    0
}

/// The positive count after a built-in's name, 1 without one.
fn count_arg(args: &[Arg], what: &[u8]) -> Option<u32> {
    match arg(args, 1) {
        None => Some(1),
        Some(n) => match parse_number(n) {
            Some(n) if n >= 0 => Some(n as u32),
            _ => {
                Out::err().b(b"sh: ").b(what).b(b": not a count: ").b(n).nl();
                None
            }
        },
    }
}

/// break [N]: leave the innermost N loops.
fn break_(sh: &mut Shell, args: &[Arg]) -> i32 {
    match count_arg(args, b"break") {
        Some(n) if n > 0 => {
            sh.flow = Some(Flow::Break(n));
            0
        }
        _ => 1,
    }
}

/// continue [N]: go on with the next round of the Nth loop out.
fn continue_(sh: &mut Shell, args: &[Arg]) -> i32 {
    match count_arg(args, b"continue") {
        Some(n) if n > 0 => {
            sh.flow = Some(Flow::Continue(n));
            0
        }
        _ => 1,
    }
}

/// return [N]: end the function (or sourced file) with N, or $?.
fn return_(sh: &mut Shell, args: &[Arg]) -> i32 {
    let status = match arg(args, 1) {
        None => sh.status,
        Some(n) => match parse_number(n) {
            Some(n) => n,
            None => {
                Out::err().b(b"sh: return: not a number: ").b(n).nl();
                return 2;
            }
        },
    };
    sh.flow = Some(Flow::Return);
    status
}

/// wait [%JOB | PID]...: wait for those background jobs, or every one
/// that is running; the last one's status.
fn wait(sh: &mut Shell, args: &[Arg]) -> i32 {
    if args.len() == 1 {
        return sh.wait_jobs(None);
    }
    let mut status = 0;
    for a in &args[1..] {
        let which = if a.text.starts_with(b"%") {
            sh.find_job(Some(&a.text)).map(WaitFor::Job)
        } else {
            parse_number(&a.text).map(|n| WaitFor::Pid(n as u32))
        };
        let Some(which) = which else {
            Out::err().b(b"sh: wait: not a job: ").b(&a.text).nl();
            return 2;
        };
        status = sh.wait_jobs(Some(which));
    }
    status
}

/// jobs: the jobs running in the background or stopped, the current
/// one (%+) marked +, the one before it -.
fn jobs(sh: &mut Shell, _: &[Arg]) -> i32 {
    sh.check_jobs();
    let mut out = Out::new(1);
    let n = sh.jobs.len();
    for (k, job) in sh.jobs.iter().enumerate() {
        let mark = if k + 1 == n { b'+' } else if k + 2 == n { b'-' } else { b' ' };
        let state: &[u8] = if job.stopped { b"stopped" } else { b"running" };
        out.c(b'[').n(job.id as i32).c(b']').c(mark).c(b' ').b(state).b(b"  ").b(&job.text).nl();
    }
    0
}

/// The job argument `k` names (current with none), or why not, said.
fn job_arg(sh: &Shell, args: &[Arg], k: usize, who: &[u8]) -> Option<usize> {
    if !sh.interactive {
        Out::err().b(b"sh: ").b(who).b(b": no job control").nl();
        return None;
    }
    let spec = arg(args, k);
    let found = sh.find_job(spec);
    if found.is_none() {
        let mut out = Out::err();
        out.b(b"sh: ").b(who).b(b": ");
        match spec {
            Some(s) => out.b(b"no such job: ").b(s).nl(),
            None => out.b(b"no current job").nl(),
        };
    }
    found
}

/// fg [%JOB]: set the job going in the foreground, giving it the
/// console, and wait for it: its status, as if typed again.
fn fg(sh: &mut Shell, args: &[Arg]) -> i32 {
    let Some(k) = job_arg(sh, args, 1, b"fg") else { return 1 };
    let job = sh.jobs.remove(k);
    Out::new(1).b(&job.text).nl();
    sh.wait_job(job, true)
}

/// bg [%JOB]...: set the stopped jobs going in the background.
fn bg(sh: &mut Shell, args: &[Arg]) -> i32 {
    let specs = args.len().max(2) - 1;
    let mut status = 0;
    for k in 1..=specs {
        let Some(at) = job_arg(sh, args, k, b"bg") else {
            status = 1;
            continue;
        };
        let job = &mut sh.jobs[at];
        crate::run::signal_job(job, sys::SIGCONT);
        job.stopped = false;
        Out::new(1).c(b'[').n(job.id as i32).b(b"] ").b(&job.text).b(b" &").nl();
    }
    status
}

/// kill [-SIGNAL | -s SIGNAL] (%JOB | PID)... and kill -l: as bin/kill,
/// and a job spec signals the job's programs, its whole group.
fn kill(sh: &mut Shell, args: &[Arg]) -> i32 {
    let text = |k: usize| core::str::from_utf8(arg(args, k).unwrap_or(b"")).unwrap_or("");
    let parse = |s: &str| match parse_number(s.as_bytes()) {
        Some(n) => (0..sys::NSIG).contains(&n).then_some(n),
        None => signal::by_name(s),
    };
    let mut sig = sys::SIGTERM;
    let mut first = 1;
    match text(1) {
        "-l" => {
            let mut out = Out::new(1);
            for (n, name) in signal::NAMES {
                if n < 10 {
                    out.c(b' ');
                }
                out.n(n).c(b' ').b(name.as_bytes()).nl();
            }
            return 0;
        }
        "-s" => {
            let Some(s) = parse(text(2)) else {
                Out::err().b(b"sh: kill: no such signal: ").b(text(2).as_bytes()).nl();
                return 2;
            };
            sig = s;
            first = 3;
        }
        opt if opt.len() > 1 && opt.starts_with('-') => {
            let Some(s) = parse(&opt[1..]) else {
                Out::err().b(b"sh: kill: no such signal: ").b(opt.as_bytes()).nl();
                return 2;
            };
            sig = s;
            first = 2;
        }
        _ => {}
    }
    if args.len() <= first {
        Out::err().b(b"usage: kill [-SIGNAL] PID|%JOB... | kill -l").nl();
        return 2;
    }
    let mut status = 0;
    for a in &args[first..] {
        let r = if a.text.starts_with(b"%") {
            match sh.find_job(Some(&a.text)) {
                Some(k) => {
                    let job = &mut sh.jobs[k];
                    crate::run::signal_job(job, sig);
                    if sig == sys::SIGCONT {
                        job.stopped = false;
                    }
                    Ok(())
                }
                None => Err(&b"no such job"[..]),
            }
        } else {
            match parse_number(&a.text) {
                Some(pid) => signal::kill(pid, sig).map(|_| ()).map_err(|e| match e.raw_os_error() {
                    Some(sys::E_NOPROC) => &b"no such process"[..],
                    Some(sys::E_PERM) => &b"not allowed"[..],
                    _ => &b"cannot signal it"[..],
                }),
                None => Err(&b"not a process or job"[..]),
            }
        };
        if let Err(why) = r {
            Out::err().b(b"sh: kill: ").b(&a.text).b(b": ").b(why).nl();
            status = 1;
        }
    }
    status
}

/// . FILE [ARG...], source FILE: run the file's commands in this shell.
fn source(sh: &mut Shell, args: &[Arg]) -> i32 {
    let Some(file) = name_arg(args) else { return 2 };
    let text = match fs::read(file) {
        Ok(t) => t,
        Err(e) => return fail(file, &e),
    };
    let file = file.to_vec();
    let given = args.len() > 2;
    let saved = given.then(|| core::mem::replace(&mut sh.params, args[2..].iter().map(|a| a.text.clone()).collect()));
    let status = sh.source(&text, &file);
    if sh.flow == Some(Flow::Return) {
        sh.flow = None;
    }
    if let Some(p) = saved {
        sh.params = p;
    }
    status
}

/// eval WORD...: run the words, joined by spaces, as a command line.
fn eval(sh: &mut Shell, args: &[Arg]) -> i32 {
    let mut text = Vec::new();
    for (k, a) in args[1..].iter().enumerate() {
        if k > 0 {
            text.push(b' ');
        }
        text.extend_from_slice(&a.text);
    }
    sh.source(&text, b"eval")
}
