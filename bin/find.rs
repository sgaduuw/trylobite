//! find [PATH]... [-name PATTERN] [-type f|d] [-maxdepth N]: say the path
//! of every file and directory under each PATH (the current directory
//! when none is given), PATH itself included, that passes every test
//! given, as Unix's find does with -print:
//!
//!   -name PATTERN  the last name matches PATTERN: `*` is any run of
//!                  characters, `?` any one, `[abc]`, `[a-z]` and `[!a]`
//!                  one of a set; quote it so the shell passes it whole
//!   -type f|d      a file, or a directory
//!   -maxdepth N    no deeper than N directories below PATH (0 is PATH)
//!
//! A directory's entries come in the order the directory holds them, and
//! each is said before what it holds. Exit with 0, or with 1 if a path
//! cannot be read (said on standard error, and the walk goes on) or
//! output fails, and 2 for an expression find does not know.
//!
//! A program has nine descriptors, so a directory is not kept open while
//! the walk is below it: its names are read into a buffer on the heap
//! first, and the directory closed. The paths still to visit wait on the
//! heap too, not in a recursion, so a deep tree needs no deep stack.
#![no_std]

use trystd::fs::{self, File};
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    File,
    Dir,
}

struct Find<'a> {
    name: Option<&'a [u8]>,
    kind: Option<Kind>,
    max_depth: usize,
    failed: bool,
}

/// Whether `name` matches the shell pattern `pat`.
fn matches(pat: &[u8], name: &[u8]) -> bool {
    // Where to go back to after a `*` fails: the pattern after it, and
    // the name one further on than last time.
    let (mut p, mut n) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while n < name.len() {
        let step = match pat.get(p) {
            Some(b'*') => {
                star = Some((p + 1, n));
                p += 1;
                continue;
            }
            Some(b'?') => Some(p + 1),
            Some(b'[') => set(pat, p, name[n]),
            Some(&c) if c == name[n] => Some(p + 1),
            _ => None,
        };
        match (step, star) {
            (Some(next), _) => {
                p = next;
                n += 1;
            }
            (None, Some((after, from))) => {
                p = after;
                n = from + 1;
                star = Some((after, from + 1));
            }
            (None, None) => return false,
        }
    }
    pat[p..].iter().all(|&c| c == b'*')
}

/// A set `[...]` at `pat[at]` tried on `c`: where the pattern goes on if
/// `c` is in it. A `[` with no `]` is itself.
fn set(pat: &[u8], at: usize, c: u8) -> Option<usize> {
    let mut i = at + 1;
    let negate = matches!(pat.get(i), Some(b'!') | Some(b'^'));
    if negate {
        i += 1;
    }
    let mut found = false;
    let mut first = true;
    while i < pat.len() && (pat[i] != b']' || first) {
        first = false;
        if pat.get(i + 1) == Some(&b'-') && pat.get(i + 2).is_some_and(|&e| e != b']') {
            found |= pat[i] <= c && c <= pat[i + 2];
            i += 3;
        } else {
            found |= pat[i] == c;
            i += 1;
        }
    }
    if i >= pat.len() {
        return (c == b'[').then_some(at + 1);
    }
    (found != negate).then_some(i + 1)
}

/// The names in directory `path`, "." and ".." left out, each ended
/// with a 0, read whole before the directory is closed.
fn names(path: &[u8]) -> io::Result<Vec<u8>> {
    let mut names: Vec<u8> = Vec::new();
    let dir = File::open(path)?;
    let mut name = [0u8; sys::NAME_MAX as usize + 1];
    while let Some(n) = dir.read_name(&mut name)? {
        if n != b"." && n != b".." {
            names.extend_from_slice(n);
            names.push(0);
        }
    }
    Ok(names)
}

impl Find<'_> {
    #[inline(never)]
    fn complain(&mut self, path: &[u8], e: &io::Error) {
        Line::new().str("find: ").bytes(path).str(": ").error(e).eprint();
        self.failed = true;
    }

    /// Test and say each path under `start`, a directory before what it
    /// holds. The paths still to visit wait on a stack, with their
    /// depths, rather than in a recursion: the program's stack is the
    /// lower half of its page.
    fn walk(&mut self, start: &str) -> io::Result<()> {
        let mut todo: Vec<(Vec<u8>, usize)> = vec![(Vec::from(start.as_bytes()), 0)];
        while let Some((path, depth)) = todo.pop() {
            let kind = match fs::metadata(&path[..]) {
                Ok(m) if m.is_dir() => Kind::Dir,
                Ok(_) => Kind::File,
                Err(e) => {
                    self.complain(&path, &e);
                    continue;
                }
            };
            let trimmed = match path.iter().rposition(|&c| c != b'/') {
                Some(end) => &path[..end + 1],
                None => &path[..], // the root
            };
            let last = match trimmed.iter().rposition(|&c| c == b'/') {
                Some(slash) => &trimmed[slash + 1..],
                None => trimmed,
            };
            if self.kind.is_none_or(|k| k == kind) && self.name.is_none_or(|pat| matches(pat, last)) {
                let mut out = io::stdout();
                out.write_all(&path)?;
                out.write_all(b"\n")?;
            }
            if kind != Kind::Dir || depth >= self.max_depth {
                continue;
            }
            let names = match names(&path) {
                Ok(n) => n,
                Err(e) => {
                    self.complain(&path, &e);
                    continue;
                }
            };
            // Last name first onto the stack, so the first comes off first.
            for name in names.split(|&c| c == 0).filter(|n| !n.is_empty()).rev() {
                let mut child = path.clone();
                if child.last() != Some(&b'/') {
                    child.push(b'/');
                }
                child.extend_from_slice(name);
                todo.push((child, depth + 1));
            }
        }
        Ok(())
    }
}

fn usage() -> i32 {
    Line::new()
        .str("usage: find [PATH]... [-name PATTERN] [-type f|d] [-maxdepth N]")
        .eprint();
    2
}

fn run() -> i32 {
    let mut args = env::args().skip(1).peekable();
    let mut paths: Vec<&str> = Vec::new();
    while let Some(path) = args.next_if(|a| !a.starts_with('-')) {
        paths.push(path);
    }
    if paths.is_empty() {
        paths.push(".");
    }
    let mut find = Find { name: None, kind: None, max_depth: usize::MAX, failed: false };
    while let Some(test) = args.next() {
        let Some(value) = args.next() else {
            return usage();
        };
        match (test, value) {
            ("-name", pat) => find.name = Some(pat.as_bytes()),
            ("-type", "f") => find.kind = Some(Kind::File),
            ("-type", "d") => find.kind = Some(Kind::Dir),
            ("-maxdepth", n) if !n.is_empty() && n.len() < 5 && n.bytes().all(|b| b.is_ascii_digit()) => {
                find.max_depth = n.bytes().fold(0, |n, b| n * 10 + (b - b'0') as usize);
            }
            _ => return usage(),
        }
    }
    for path in paths {
        if find.walk(path).and_then(|()| io::stdout().flush()).is_err() {
            return 1;
        }
    }
    find.failed as i32
}
