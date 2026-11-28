//! Running what the parser made: lists, and-or lists, pipelines and
//! commands, their redirections, and the programs they start.
//!
//! A pipeline's commands are joined by pipes (the pipe server's): each
//! one's standard output is the next one's standard input. Every program
//! of a pipeline starts before the shell waits for any, so they run side
//! by side, and the shell keeps its end of each pipe out of the children
//! (FD_NOINHERIT), so that a reader sees the end once its writer has
//! gone. What runs in the shell itself (a built-in, a function, a
//! compound command) takes one place in a pipeline and runs once every
//! program has started, since two would wait for each other; with no
//! fork, it cannot run in the background either.
//!
//! Redirections (< > >> and N>&M, on a command or after a compound one)
//! change the shell's own descriptors while the command starts or runs,
//! then the shell puts them back: what each held waits in a spare
//! descriptor, kept out of children, on a stack (`saves`). A process has
//! only NDESC (9) descriptors, so redirections nest only so deep.
//!
//! A command's status is a program's exit code, 128 and the signal for
//! one a signal ended, 255 for a fault, a built-in's own, 127 or 126 for
//! a program not found or not started, and 1 for a command the shell
//! could not start (a redirection's file); a pipeline's is its last
//! command's, negated by !.

use alloc::rc::Rc;
use trystd::env;
use trystd::fs::{self, OpenOptions};
use trystd::prelude::*;
use trystd::process::{self, Child};
use trystd::{console, os, sys};

use crate::Shell;
use crate::builtin::{self, Builtin};
use crate::expand::{Arg, assignment};
use crate::fail;
use crate::glob;
use crate::lex::{Redir, Tok};
use crate::out::Out;
use crate::parse::{Command, Item, List, Node, Pipeline, Redirect};

/// Statuses of commands that never ran, as Unix shells give them.
pub const NOT_FOUND: i32 = 127;
pub const NOT_STARTED: i32 = 126;
/// The status of a command the shell stopped before it ran.
pub const FAILED: i32 = 1;

/// Programs of the kernel image the shell starts by number (shell.s);
/// everything else is on the disk.
pub const PROGRAMS: &[(&[u8], i32)] = &[(b"pingpong", 3)];

/// What breaks the run of a list: break N, continue N, return.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    Break(u32),
    Continue(u32),
    Return,
}

/// Something that runs in the shell, waiting for the programs of its
/// pipeline to start.
enum Job<'a> {
    Builtin(Builtin, Vec<Arg>, Vec<(Vec<u8>, Vec<u8>)>, &'a [Redirect]),
    Function(Rc<Command>, Vec<Arg>, &'a [Redirect]),
    Compound(&'a Command),
}

/// What starting a command came to.
enum Started<'a> {
    Program(Child),
    Shell(Job<'a>),
    /// Assignments or redirections alone, done: their status.
    Done(i32),
}

/// It has been said why a command did not start; the status it leaves.
pub struct Stop(pub i32);

/// A pipeline running in the background.
pub struct BgJob {
    pub id: u32,
    pub children: Vec<Child>,
    pub text: Vec<u8>,
}

impl Shell {
    /// Run a list: each and-or list in turn, until break, continue or
    /// return. Its status, the last one's.
    pub fn run_list(&mut self, list: &List) -> i32 {
        for item in list {
            if self.flow.is_some() {
                break;
            }
            self.status = self.run_item(item);
        }
        self.status
    }

    fn run_item(&mut self, item: &Item) -> i32 {
        if item.background {
            if !item.rest.is_empty() || item.first.bang {
                Out::err().b(b"sh: only a pipeline of programs runs in the background").nl();
                return FAILED;
            }
            return self.pipeline(&item.first.cmds, true);
        }
        let mut status = self.run_pipeline(&item.first, !item.rest.is_empty());
        for (k, (and, p)) in item.rest.iter().enumerate() {
            if self.flow.is_some() {
                break;
            }
            if *and == (status == 0) {
                self.status = status;
                status = self.run_pipeline(p, k + 1 < item.rest.len());
            }
        }
        status
    }

    /// A pipeline whose status the caller tests (&&, ||, !) does not say
    /// how its programs ended.
    fn run_pipeline(&mut self, p: &Pipeline, tested: bool) -> i32 {
        let tested = tested || p.bang;
        self.testing += tested as u32;
        let status = self.pipeline(&p.cmds, false);
        self.testing -= tested as u32;
        if p.bang { (status == 0) as i32 } else { status }
    }

    /// Run the commands of a pipeline; in the background, its programs
    /// are left running as a job.
    fn pipeline(&mut self, cmds: &[Command], background: bool) -> i32 {
        let mark = self.saves.len();
        let mut children: Vec<Option<Child>> = Vec::new();
        let r = self.stages(cmds, background, &mut children);
        self.restore_to(mark);
        self.close_strays();
        if background {
            let started: Vec<Child> = children.into_iter().flatten().collect();
            if let Some(last) = started.last() {
                self.last_bg = Some(last.id());
                let id = self.jobs.iter().map(|j| j.id).max().unwrap_or(0) + 1;
                if self.interactive {
                    Out::err().c(b'[').n(id as i32).b(b"] ").n(last.id() as i32).nl();
                }
                self.jobs.push(BgJob { id, children: started, text: describe(cmds) });
            }
            return match r {
                Err(Stop(status)) => status,
                Ok(_) => 0,
            };
        }
        let n = children.len();
        let mut status = 0;
        for (k, child) in children.iter_mut().enumerate() {
            if let Some(child) = child {
                let s = self.reap(child);
                if k + 1 == n {
                    status = s;
                }
            }
        }
        match r {
            Err(Stop(s)) => s,
            Ok(Some(s)) => s, // the last command ran in the shell
            Ok(None) => status,
        }
    }

    /// Start every command of a pipeline, each program into `children`;
    /// the status of the last if it ran in the shell.
    fn stages<'a>(
        &mut self,
        cmds: &'a [Command],
        background: bool,
        children: &mut Vec<Option<Child>>,
    ) -> Result<Option<i32>, Stop> {
        let n = cmds.len();
        if n == 1 {
            return match self.start(&cmds[0])? {
                Started::Program(child) => {
                    children.push(Some(child));
                    Ok(None)
                }
                Started::Shell(job) => {
                    if background {
                        return say(b"sh: only programs run in the background");
                    }
                    Ok(Some(self.run_job(job)))
                }
                Started::Done(status) => Ok(Some(status)),
            };
        }
        // The shell's standard input and output, which the first and
        // last commands get.
        let mark = self.saves.len();
        self.save_fd(sys::STDIN)?;
        self.save_fd(sys::STDOUT)?;
        let (shell_in, shell_out) = (self.saves[mark].1, self.saves[mark + 1].1);
        let mut read_end: Option<i32> = None;
        let mut parked: Option<(Job<'a>, i32, i32)> = None;
        let mut last_shell = false;
        let r = (|| {
            for (k, cmd) in cmds.iter().enumerate() {
                match read_end.take() {
                    Some(r) => {
                        let _ = fs::dup2(r, sys::STDIN);
                        fs::close(r);
                    }
                    None => put(shell_in, sys::STDIN),
                }
                if k + 1 == n {
                    put(shell_out, sys::STDOUT);
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
                    Started::Program(child) => children.push(Some(child)),
                    Started::Shell(job) => {
                        if background {
                            return say(b"sh: only programs run in the background");
                        }
                        if parked.is_some() {
                            return say(b"sh: one built-in to a pipeline");
                        }
                        let into = spare().ok_or_else(too_many)?;
                        park(sys::STDIN, into);
                        let out = spare().ok_or_else(too_many)?;
                        park(sys::STDOUT, out);
                        parked = Some((job, into, out));
                        last_shell = k + 1 == n;
                        children.push(None);
                    }
                    Started::Done(_) => children.push(None),
                }
            }
            Ok(())
        })();
        if let Some(r) = read_end {
            fs::close(r);
        }
        if let Err(stop) = r {
            if let Some((_, i, o)) = parked {
                fs::close(i);
                fs::close(o);
            }
            return Err(stop);
        }
        if let Some((job, into, out)) = parked {
            let _ = fs::dup2(into, sys::STDIN);
            let _ = fs::dup2(out, sys::STDOUT);
            fs::close(into);
            fs::close(out);
            let status = self.run_job(job);
            if last_shell {
                return Ok(Some(status));
            }
        }
        Ok(None)
    }

    /// Start a command: a program it starts, or what runs in the shell,
    /// left to the caller to run.
    fn start<'a>(&mut self, cmd: &'a Command) -> Result<Started<'a>, Stop> {
        match &cmd.node {
            Node::Simple(words) => self.simple(words, &cmd.redirs),
            Node::Function(name, body) => {
                self.functions.retain(|(n, _)| n != name);
                self.functions.push((name.clone(), body.clone()));
                Ok(Started::Done(0))
            }
            _ => Ok(Started::Shell(Job::Compound(cmd))),
        }
    }

    /// A simple command: assignments, then its words expanded, then a
    /// built-in or function (to run in the shell), or a program, started
    /// with the command's redirections and assignments.
    fn simple<'a>(&mut self, words: &[Tok], redirs: &'a [Redirect]) -> Result<Started<'a>, Stop> {
        let mut assigns = Vec::new();
        let mut rest = words.iter().peekable();
        while let Some((name, value)) = rest.peek().and_then(|w| assignment(&w.text)) {
            assigns.push((name.to_vec(), self.expand_one(value)));
            rest.next();
        }
        let mut args: Vec<Arg> = Vec::new();
        for w in rest {
            for (k, text) in self.expand(&w.text).into_iter().enumerate() {
                // The spaces typed before the word, or one between the
                // arguments a value split into.
                let gap = if args.is_empty() { 0 } else if k == 0 { w.gap.max(1) } else { 1 };
                args.push(Arg { text, gap });
            }
        }
        let Some(name) = args.first().map(|a| a.text.clone()) else {
            // Redirections alone make their files; assignments set the
            // shell's variables.
            let mark = self.saves.len();
            let r = self.redirect_all(redirs);
            self.restore_to(mark);
            r?;
            for (name, value) in &assigns {
                if !self.vars.set(name, value) {
                    return Err(Stop(FAILED));
                }
            }
            return Ok(Started::Done(0));
        };
        if let Some(body) = self.function(&name) {
            return Ok(Started::Shell(Job::Function(body, args, redirs)));
        }
        // ls with an option (ls -l) is /bin/ls's: the built-in knows none.
        let option = name == b"ls" && args.get(1).is_some_and(|a| a.text.first() == Some(&b'-'));
        if let Some(f) = builtin::find(&name).filter(|_| !option) {
            return Ok(Started::Shell(Job::Builtin(f, args, assigns, redirs)));
        }
        let mark = self.saves.len();
        if let Err(stop) = self.redirect_all(redirs) {
            self.restore_to(mark);
            return Err(stop);
        }
        let old = set_env(&assigns);
        let started = self.spawn(&name, &args);
        restore_env(old);
        self.restore_to(mark);
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

    pub fn function(&self, name: &[u8]) -> Option<Rc<Command>> {
        self.functions.iter().find(|(n, _)| n == name).map(|(_, b)| b.clone())
    }

    /// Run what runs in the shell, with its redirections meanwhile.
    fn run_job(&mut self, job: Job) -> i32 {
        let mark = self.saves.len();
        let redirs = match &job {
            Job::Builtin(_, _, _, r) | Job::Function(_, _, r) => *r,
            Job::Compound(cmd) => &cmd.redirs[..],
        };
        if let Err(Stop(status)) = self.redirect_all(redirs) {
            self.restore_to(mark);
            return status;
        }
        let status = match job {
            Job::Builtin(f, args, assigns, _) => {
                let old = set_env(&assigns);
                let status = f(self, &args);
                restore_env(old);
                status
            }
            Job::Function(body, args, _) => self.call(&body, &args),
            Job::Compound(cmd) => self.compound(&cmd.node),
        };
        self.restore_to(mark);
        status
    }

    /// Call a function: its arguments are the positional parameters
    /// while it runs, and return ends it.
    pub fn call(&mut self, body: &Command, args: &[Arg]) -> i32 {
        if self.depth >= MAX_DEPTH {
            Out::err().b(b"sh: functions call each other too deep").nl();
            return FAILED;
        }
        let params = args[1..].iter().map(|a| a.text.clone()).collect();
        let saved = core::mem::replace(&mut self.params, params);
        self.depth += 1;
        let status = match &body.node {
            Node::Simple(_) | Node::Function(..) => FAILED,
            _ => {
                let mark = self.saves.len();
                match self.redirect_all(&body.redirs) {
                    Ok(()) => {
                        let s = self.compound(&body.node);
                        self.restore_to(mark);
                        s
                    }
                    Err(Stop(s)) => {
                        self.restore_to(mark);
                        s
                    }
                }
            }
        };
        self.depth -= 1;
        self.params = saved;
        if self.flow == Some(Flow::Return) {
            self.flow = None;
        }
        status
    }

    fn compound(&mut self, node: &Node) -> i32 {
        match node {
            Node::If(arms, els) => {
                for (cond, body) in arms {
                    let s = self.condition(cond);
                    if self.flow.is_some() {
                        return s;
                    }
                    if s == 0 {
                        return self.run_list(body);
                    }
                }
                match els {
                    Some(body) => self.run_list(body),
                    None => 0,
                }
            }
            Node::Loop(until, cond, body) => {
                let mut status = 0;
                loop {
                    let s = self.condition(cond);
                    if self.flow.is_some() || (s == 0) == *until {
                        break;
                    }
                    status = self.run_list(body);
                    if self.loop_flow() {
                        break;
                    }
                }
                status
            }
            Node::For(name, words, body) => {
                let values: Vec<Vec<u8>> = match words {
                    Some(words) => {
                        let mut v = Vec::new();
                        for w in words {
                            v.extend(self.expand(&w.text));
                        }
                        v
                    }
                    None => self.params.clone(),
                };
                let mut status = 0;
                for v in values {
                    if !self.vars.set(name, &v) {
                        return FAILED;
                    }
                    status = self.run_list(body);
                    if self.loop_flow() {
                        break;
                    }
                }
                status
            }
            Node::Case(word, arms) => {
                let w = self.expand_one(&word.text);
                for (patterns, body) in arms {
                    for p in patterns {
                        let (pat, quoted) = self.expand_quoted(&p.text);
                        if glob::matches(&pat, &quoted, &w) {
                            return self.run_list(body);
                        }
                    }
                }
                0
            }
            Node::Group(list) => self.run_list(list),
            Node::Simple(_) | Node::Function(..) => FAILED,
        }
    }

    /// An if's or a loop's condition, whose status is tested.
    fn condition(&mut self, cond: &List) -> i32 {
        self.testing += 1;
        let s = self.run_list(cond);
        self.testing -= 1;
        s
    }

    /// After a loop's body: whether break or continue ends this loop,
    /// taking off what this loop answers for.
    fn loop_flow(&mut self) -> bool {
        match self.flow {
            Some(Flow::Break(n)) => {
                self.flow = (n > 1).then(|| Flow::Break(n - 1));
                true
            }
            Some(Flow::Continue(n)) => {
                if n > 1 {
                    self.flow = Some(Flow::Continue(n - 1));
                    true
                } else {
                    self.flow = None;
                    false
                }
            }
            Some(Flow::Return) => true,
            None => false,
        }
    }

    // --- redirections ------------------------------------------------------------

    fn redirect_all(&mut self, redirs: &[Redirect]) -> Result<(), Stop> {
        for r in redirs {
            self.redirect(r)?;
        }
        Ok(())
    }

    /// Point descriptor r.fd where `r` says, keeping what it held.
    fn redirect(&mut self, r: &Redirect) -> Result<(), Stop> {
        let fd = r.fd;
        if !(0..=2).contains(&fd) {
            return say(b"sh: only descriptors 0 to 2 can be redirected");
        }
        if r.how == Redir::Dup {
            let from = (r.target.text[0] - b'0') as i32;
            if from == fd {
                return Ok(());
            }
            if !(0..=2).contains(&from) || !fs::is_open(from) {
                Out::err().b(b"sh: ").n(from).b(b": not an open descriptor").nl();
                return Err(Stop(FAILED));
            }
            self.save_fd(fd)?;
            let _ = fs::dup2(from, fd);
            return Ok(());
        }
        let opens = match r.how {
            Redir::In => OpenOptions::new().read(true).clone(),
            Redir::Out => OpenOptions::new().write(true).create(true).truncate(true).clone(),
            _ => OpenOptions::new().write(true).create(true).append(true).clone(),
        };
        let mut paths = self.expand(&r.target.text);
        if paths.len() != 1 {
            return say(b"sh: which file?");
        }
        let path = paths.pop().unwrap_or_default();
        self.save_fd(fd)?;
        let file = match opens.open(&path) {
            Ok(file) => file.into_fd(),
            Err(e) => {
                fail(&path, &e);
                return Err(Stop(FAILED));
            }
        };
        if file.raw() == fd {
            file.into_raw(); // it came there itself: keep it open
        } else {
            let _ = fs::dup2(file.raw(), fd);
        }
        Ok(())
    }

    /// Keep what descriptor `fd` holds in a spare one, out of children,
    /// to put back with `restore_to`; once per descriptor per command.
    pub fn save_fd(&mut self, fd: i32) -> Result<(), Stop> {
        if !fs::is_open(fd) {
            self.saves.push((fd, None));
            return Ok(());
        }
        let Some(copy) = spare() else {
            return Err(too_many());
        };
        park(fd, copy);
        self.saves.push((fd, Some(copy)));
        Ok(())
    }

    /// Put back every descriptor saved since `mark`, last first.
    pub fn restore_to(&mut self, mark: usize) {
        while self.saves.len() > mark {
            let (fd, copy) = self.saves.pop().unwrap_or((0, None));
            fs::close(fd);
            if let Some(c) = copy {
                let _ = fs::dup2(c, fd);
                fs::close(c);
            }
        }
    }

    /// Close whatever a pipeline that stopped partway left open, so that
    /// its programs see their pipes end: every descriptor past 2 that
    /// holds nothing saved.
    fn close_strays(&mut self) {
        for fd in sys::STDERR + 1..sys::NDESC {
            if !self.saves.iter().any(|&(_, c)| c == Some(fd)) {
                fs::close(fd);
            }
        }
    }

    // --- programs ----------------------------------------------------------------

    /// Start program `name`: one of the image's, a path, or a file in
    /// one of $PATH's directories, the first that has it. A file that
    /// starts with #! runs the program it names, with the file's path.
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
            return spawn_file(name, &block, args);
        }
        let path = self.vars.get(b"PATH").unwrap_or(crate::vars::PATH);
        let mut last = io::Error::from_raw(sys::E_NOENT);
        for dir in path.split(|&c| c == b':') {
            let mut file = if dir.is_empty() { b".".to_vec() } else { dir.to_vec() };
            file.push(b'/');
            file.extend_from_slice(name);
            match spawn_file(&file, &block, args) {
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

    /// Give the console to `child` while it runs, so that Ctrl-C ends it,
    /// wait for it, and say how it ended if not with 0 (but for a status
    /// that is tested, or in a script, only a fault or a signal): on
    /// standard error, since it is about the program, not its output.
    /// Its status.
    fn reap(&mut self, child: &mut Child) -> i32 {
        // A shell whose input is not the console (a remote shell's,
        // bin/telnetd) leaves the console to whoever has it.
        let console = crate::on_console();
        if console {
            let _ = console::set_foreground(Some(child.id()));
        }
        let status = child.wait();
        // The console is the shell's again before another program can
        // have this one's number.
        if console {
            let _ = console::set_foreground(None);
        }
        let Ok(status) = status else { return FAILED };
        let (code, said) = describe_status(&status);
        if let Some(said) = said {
            let quiet = self.testing > 0 || (!self.interactive && status.code().is_some());
            if !quiet {
                Out::err().b(b"sh: ").b(&said).nl();
            }
        }
        code
    }

    /// Say which background jobs have ended, and forget them: before a
    /// prompt. A job is done when each of its programs has ended, which
    /// the process table says without waiting.
    pub fn check_jobs(&mut self) {
        let mut k = 0;
        while k < self.jobs.len() {
            let ended = self.jobs[k].children.iter().all(|c| {
                os::process(c.id()).is_none_or(|p| p.state == os::State::Zombie)
            });
            if !ended {
                k += 1;
                continue;
            }
            let mut job = self.jobs.remove(k);
            let status = job.children.iter_mut().map(|c| c.wait()).last();
            let mut out = Out::err();
            out.c(b'[').n(job.id as i32).b(b"] ");
            match status {
                Some(Ok(s)) if s.success() => out.b(b"done  "),
                Some(Ok(s)) => {
                    let (code, _) = describe_status(&s);
                    out.b(b"exit ").n(code).b(b"  ")
                }
                _ => out.b(b"done  "),
            };
            out.b(&job.text).nl();
        }
    }

    /// Wait for background job `id`, or every one: the last one's status.
    pub fn wait_jobs(&mut self, which: Option<WaitFor>) -> i32 {
        let mut status = 0;
        let mut k = 0;
        let mut found = which.is_none();
        while k < self.jobs.len() {
            let hit = match which {
                None => true,
                Some(WaitFor::Job(id)) => self.jobs[k].id == id,
                Some(WaitFor::Pid(pid)) => self.jobs[k].children.iter().any(|c| c.id() == pid),
            };
            if !hit {
                k += 1;
                continue;
            }
            found = true;
            let mut job = self.jobs.remove(k);
            for c in job.children.iter_mut() {
                if let Ok(s) = c.wait() {
                    status = describe_status(&s).0;
                }
            }
        }
        if !found {
            return NOT_FOUND;
        }
        status
    }
}

/// What `wait` waits for: %N or a process number.
#[derive(Clone, Copy)]
pub enum WaitFor {
    Job(u32),
    Pid(u32),
}

/// How deep functions may call each other: each call takes stack.
pub const MAX_DEPTH: u32 = 40;

/// A status as a number, and what to say about it, if anything.
fn describe_status(status: &process::ExitStatus) -> (i32, Option<Vec<u8>>) {
    let num = crate::expand::number;
    if let Some(code) = status.code() {
        let said = (code != 0).then(|| [&b"exit "[..], &num(code)].concat());
        return (code, said);
    }
    if let Some(cause) = status.fault() {
        return (255, Some([&b"fault "[..], &num(cause)].concat()));
    }
    let sig = status.signal().unwrap_or(sys::SIGKILL);
    // A writer whose reader left: as Unix shells, nothing to say.
    (128 + sig, (sig != sys::SIGPIPE).then(|| b"killed".to_vec()))
}

/// A pipeline's words as typed, for `jobs`.
fn describe(cmds: &[Command]) -> Vec<u8> {
    let mut text = Vec::new();
    for (k, cmd) in cmds.iter().enumerate() {
        if k > 0 {
            text.extend_from_slice(b" | ");
        }
        if let Node::Simple(words) = &cmd.node {
            for (j, w) in words.iter().enumerate() {
                if j > 0 {
                    text.push(b' ');
                }
                text.extend_from_slice(&w.text);
            }
        }
    }
    text
}

/// Start the program file at `path`; one that starts with #! by the
/// program its first line names, given the file's path and arguments.
fn spawn_file(path: &[u8], block: &[u8], args: &[Arg]) -> io::Result<Child> {
    let e = match process::spawn_file(path, block) {
        Ok(child) => return Ok(child),
        Err(e) => e,
    };
    if e.raw_os_error() != Some(sys::E_NOEXEC) {
        return Err(e);
    }
    let mut head = [0u8; 81];
    let n = fs::File::open(path).and_then(|mut f| f.read(&mut head)).unwrap_or(0);
    let Some(line) = head[..n].strip_prefix(b"#!") else { return Err(e) };
    let line = &line[..line.iter().position(|&c| c == b'\n').unwrap_or(line.len())];
    let mut words = line.split(|&c| c == b' ' || c == b'\t').filter(|w| !w.is_empty());
    let Some(interp) = words.next() else { return Err(e) };
    let mut b = Vec::new();
    for w in core::iter::once(interp).chain(words.next()).chain(core::iter::once(path)) {
        b.extend_from_slice(w);
        b.push(0);
    }
    for a in &args[1..] {
        b.extend_from_slice(&a.text);
        b.push(0);
    }
    process::spawn_file(interp, &b)
}

/// Put assignments in the environment: what each name had, to go back.
pub fn set_env(assigns: &[(Vec<u8>, Vec<u8>)]) -> Vec<(Vec<u8>, Option<Vec<u8>>)> {
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
pub fn restore_env(old: Vec<(Vec<u8>, Option<Vec<u8>>)>) {
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

fn too_many() -> Stop {
    Out::err().b(b"sh: no descriptor left to redirect with").nl();
    Stop(FAILED)
}

/// The highest descriptor past 2 that holds nothing.
fn spare() -> Option<i32> {
    (sys::STDERR + 1..sys::NDESC).rev().find(|&fd| !fs::is_open(fd))
}

/// Copy descriptor `fd` to `to`, kept out of children.
fn park(fd: i32, to: i32) {
    if fs::dup2(fd, to).is_ok() {
        let _ = fs::set_inherit(to, false);
    }
}

/// Point descriptor `fd` at what `copy` holds, or close it for none.
fn put(copy: Option<i32>, fd: i32) {
    match copy {
        Some(c) => {
            let _ = fs::dup2(c, fd);
        }
        None => fs::close(fd),
    }
}
