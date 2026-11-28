//! diff [-u] FILE1 FILE2: say how the lines of FILE1 must change to
//! become those of FILE2, as Unix's diff does; `-` for either is
//! standard input. Without -u the output is diff's own: for each change
//! a line such as `3c3,4`, `5d4` or `7a9`, the lines of FILE1 taken away
//! after `< `, then `---` between them and the lines of FILE2 put in
//! after `> `. With -u it is a unified diff, as patch reads: `--- FILE1`
//! and `+++ FILE2`, then hunks headed `@@ -l,n +l,n @@` holding three
//! lines of context around the changes, the lines taken away after `-`
//! and those put in after `+`. A last line with no newline is followed
//! by `\ No newline at end of file`. Exit with 0 if the files are the
//! same, 1 if they differ, and 2 if one cannot be read (said on standard
//! error) or output fails.
//!
//! The changes are a shortest edit script, from Myers' O(ND) algorithm
//! ("An O(ND) Difference Algorithm and Its Variations", 1986), after the
//! lines the two files start and end with alike are set aside: a pass
//! for each count of changes D, keeping each pass's furthest points for
//! the way back, so memory grows as D squared. Both files are held whole,
//! on the heap.
#![no_std]

use trystd::fs::File;
use trystd::prelude::*;

trystd::main!(run);

/// Lines of context around a change in a unified diff.
const CONTEXT: usize = 3;

/// A file's text and its lines: where each starts and ends in the text,
/// its newline included, with a hash of each to compare by first.
struct Text {
    bytes: Vec<u8>,
    lines: Vec<(usize, usize)>,
    hashes: Vec<u32>,
}

impl Text {
    fn read(name: &str) -> io::Result<Text> {
        let mut bytes = Vec::new();
        if name == "-" {
            io::stdin().read_to_end(&mut bytes)?;
        } else {
            File::open(name)?.read_to_end(&mut bytes)?;
        }
        let mut lines = Vec::new();
        let mut hashes = Vec::new();
        let mut start = 0;
        let mut hash: u32 = 2_166_136_261; // FNV-1a
        for (i, &b) in bytes.iter().enumerate() {
            hash = (hash ^ b as u32).wrapping_mul(16_777_619);
            if b == b'\n' || i + 1 == bytes.len() {
                lines.push((start, i + 1));
                hashes.push(hash);
                start = i + 1;
                hash = 2_166_136_261;
            }
        }
        Ok(Text { bytes, lines, hashes })
    }

    fn line(&self, i: usize) -> &[u8] {
        let (start, end) = self.lines[i];
        &self.bytes[start..end]
    }

    fn len(&self) -> usize {
        self.lines.len()
    }
}

fn same(a: &Text, i: usize, b: &Text, j: usize) -> bool {
    a.hashes[i] == b.hashes[j] && a.line(i) == b.line(j)
}

/// A change: lines a.0..a.1 of the first file become b.0..b.1 of the
/// second, counted from 0, either range possibly empty.
#[derive(Clone, Copy)]
struct Change {
    a: (usize, usize),
    b: (usize, usize),
}

/// The changes that turn `a` into `b`, in order.
fn changes(a: &Text, b: &Text) -> Vec<Change> {
    // Set aside the lines both start and end with.
    let mut lo = 0;
    while lo < a.len() && lo < b.len() && same(a, lo, b, lo) {
        lo += 1;
    }
    let (mut ea, mut eb) = (a.len(), b.len());
    while ea > lo && eb > lo && same(a, ea - 1, b, eb - 1) {
        ea -= 1;
        eb -= 1;
    }
    let (n, m) = ((ea - lo) as isize, (eb - lo) as isize);
    let max = n + m;
    // v[k + off] is the furthest x reached on diagonal k = x - y.
    let off = max + 1;
    let mut v = vec![0isize; (2 * max + 3) as usize];
    // trace holds v as each pass d found it, diagonals -(d+1)..=d+1, at
    // d * (d + 2): what the way back reads.
    let mut trace: Vec<isize> = Vec::new();
    let mut found = 0;
    'passes: for d in 0..=max {
        trace.extend_from_slice(&v[(off - d - 1) as usize..=(off + d + 1) as usize]);
        let mut k = -d;
        while k <= d {
            let i = (off + k) as usize;
            let mut x = if k == -d || (k != d && v[i - 1] < v[i + 1]) { v[i + 1] } else { v[i - 1] + 1 };
            let mut y = x - k;
            while x < n && y < m && same(a, (lo as isize + x) as usize, b, (lo as isize + y) as usize) {
                x += 1;
                y += 1;
            }
            v[i] = x;
            if x >= n && y >= m {
                found = d;
                break 'passes;
            }
            k += 2;
        }
    }

    // Back from the end, a pass at a time, gathering runs of lines taken
    // away and put in into changes.
    let mut out: Vec<Change> = Vec::new();
    let (mut x, mut y) = (n, m);
    let mut d = found;
    while d > 0 {
        let at = |k: isize| trace[(d * (d + 2) + k + d + 1) as usize];
        let k = x - y;
        let prev_k = if k == -d || (k != d && at(k - 1) < at(k + 1)) { k + 1 } else { k - 1 };
        let prev_x = at(prev_k);
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            x -= 1;
            y -= 1;
        }
        // One line: taken away (x moved) or put in (y moved).
        let (ax, by) = ((lo as isize + x) as usize, (lo as isize + y) as usize);
        let one = if x == prev_x {
            Change { a: (ax, ax), b: (by - 1, by) }
        } else {
            Change { a: (ax - 1, ax), b: (by, by) }
        };
        match out.last_mut() {
            Some(c) if c.a.0 == one.a.1 && c.b.0 == one.b.1 => {
                c.a.0 = one.a.0;
                c.b.0 = one.b.0;
            }
            _ => out.push(one),
        }
        x = prev_x;
        y = prev_y;
        d -= 1;
    }
    out.reverse();
    out
}

/// Lines s..e as diff numbers them: `s+1` or `s+1,e`, or for no lines
/// the line before them.
fn range(line: &mut Line, (s, e): (usize, usize)) {
    if e <= s + 1 {
        line.num(e as i64);
    } else {
        line.num(s as i64 + 1).byte(b',').num(e as i64);
    }
}

/// The same for a unified hunk's header: `l` alone for one line, and
/// `l,n` otherwise, with l the line before for none.
fn hunk_range(line: &mut Line, (s, e): (usize, usize)) {
    if e == s + 1 {
        line.num(e as i64);
    } else {
        line.num(if e == s { s } else { s + 1 } as i64).byte(b',').num((e - s) as i64);
    }
}

/// Line `i` of `t` after `mark`, with the note a line with no newline gets.
fn put(out: &mut io::Stdout, mark: &[u8], t: &Text, i: usize) -> io::Result<()> {
    let line = t.line(i);
    out.write_all(mark)?;
    out.write_all(line)?;
    if line.last() != Some(&b'\n') {
        out.write_all(b"\n\\ No newline at end of file\n")?;
    }
    Ok(())
}

fn normal(a: &Text, b: &Text, changes: &[Change]) -> io::Result<()> {
    let mut out = io::stdout();
    for c in changes {
        let mut head = Line::new();
        range(&mut head, c.a);
        head.byte(match (c.a.0 == c.a.1, c.b.0 == c.b.1) {
            (true, _) => b'a',
            (_, true) => b'd',
            _ => b'c',
        });
        range(&mut head, c.b);
        head.print()?;
        for i in c.a.0..c.a.1 {
            put(&mut out, b"< ", a, i)?;
        }
        if c.a.0 < c.a.1 && c.b.0 < c.b.1 {
            out.write_all(b"---\n")?;
        }
        for j in c.b.0..c.b.1 {
            put(&mut out, b"> ", b, j)?;
        }
    }
    out.flush()
}

fn unified(a: &Text, b: &Text, changes: &[Change], names: [&str; 2]) -> io::Result<()> {
    let mut out = io::stdout();
    Line::new().str("--- ").str(names[0]).print()?;
    Line::new().str("+++ ").str(names[1]).print()?;
    let mut first = 0;
    while first < changes.len() {
        // A hunk: the changes whose context would touch or overlap.
        let mut last = first;
        while last + 1 < changes.len() && changes[last + 1].a.0 - changes[last].a.1 <= 2 * CONTEXT {
            last += 1;
        }
        let (c0, c1) = (changes[first], changes[last]);
        let a0 = c0.a.0.saturating_sub(CONTEXT);
        let a1 = (c1.a.1 + CONTEXT).min(a.len());
        let b0 = c0.b.0 - (c0.a.0 - a0);
        let b1 = c1.b.1 + (a1 - c1.a.1);
        let mut head = Line::new();
        head.str("@@ -");
        hunk_range(&mut head, (a0, a1));
        head.str(" +");
        hunk_range(&mut head, (b0, b1));
        head.str(" @@").print()?;
        let mut i = a0;
        for c in &changes[first..=last] {
            for k in i..c.a.0 {
                put(&mut out, b" ", a, k)?;
            }
            for k in c.a.0..c.a.1 {
                put(&mut out, b"-", a, k)?;
            }
            for k in c.b.0..c.b.1 {
                put(&mut out, b"+", b, k)?;
            }
            i = c.a.1;
        }
        for k in i..a1 {
            put(&mut out, b" ", a, k)?;
        }
        first = last + 1;
    }
    out.flush()
}

fn usage() -> i32 {
    Line::new().str("usage: diff [-u] FILE1 FILE2").eprint();
    2
}

fn run() -> i32 {
    let mut args = env::args().skip(1).peekable();
    let mut unified_diff = false;
    if args.peek() == Some(&"-u") {
        args.next();
        unified_diff = true;
    }
    let (Some(first), Some(second), None) = (args.next(), args.next(), args.next()) else {
        return usage();
    };
    let names = [first, second];
    let texts = names.map(|name| {
        Text::read(name).map_err(|e| {
            Line::new().str("diff: ").str(name).str(": ").error(&e).eprint();
        })
    });
    let (Ok(a), Ok(b)) = (&texts[0], &texts[1]) else {
        return 2;
    };
    let changes = changes(a, b);
    if changes.is_empty() {
        return 0;
    }
    let written = if unified_diff { unified(a, b, &changes, names) } else { normal(a, b, &changes) };
    if written.is_err() { 2 } else { 1 }
}
