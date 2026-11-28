//! sort [-bfnru] [-t C] [-k N[,M]] [-o FILE] [FILE]...: the lines of the
//! files, or of standard input when none is named (or for `-`), sorted,
//! on standard output, as Unix's sort does:
//!
//!   -n        by the number each key starts with (blanks, a sign, digits
//!             and a fraction; anything else counts as 0)
//!   -f        upper and lower case alike
//!   -b        blanks at the start of a key left out
//!   -r        in reverse
//!   -u        each key once: the first of the lines whose keys are equal
//!   -t C      fields are separated by C (by blanks when not given)
//!   -k N[,M]  the key runs from field N to the end of field M (to the end
//!             of the line without M), counted from 1; letters after a
//!             number (-k2n) set those options for the whole sort
//!   -o FILE   the output to FILE, made or emptied once every input is
//!             read, so that `sort -o f f` sorts f in place
//!
//! Lines whose keys are equal keep their order (the sort is stable),
//! unless -u keeps only the first; without -u, lines whose keys are
//! equal are then compared whole, as POSIX asks. A last line with no
//! newline gets one. Exit with 0, or with 2 if a file cannot be read or
//! written (said on standard error) or an option is wrong.
//!
//! Every line is read into one Vec<u8> on the heap, with the start and
//! end of each line in another, and the second sorted.
#![no_std]

use core::cmp::Ordering;

use trystd::fs::File;
use trystd::prelude::*;

trystd::main!(run);

#[derive(Default)]
struct Order {
    numeric: bool,
    fold: bool,
    blanks: bool,
    reverse: bool,
    unique: bool,
    /// The field separator, or None for runs of blanks.
    sep: Option<u8>,
    /// The key's first and last fields, from 0; None for the whole line.
    key: Option<(usize, Option<usize>)>,
}

fn blank(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

impl Order {
    /// Where field `n` of `line` starts, and where it ends.
    fn field(&self, line: &[u8], n: usize) -> (usize, usize) {
        let mut i = 0;
        match self.sep {
            Some(sep) => {
                for _ in 0..n {
                    match line[i..].iter().position(|&b| b == sep) {
                        Some(k) => i += k + 1,
                        None => return (line.len(), line.len()),
                    }
                }
                let end = line[i..].iter().position(|&b| b == sep).map_or(line.len(), |k| i + k);
                (i, end)
            }
            None => {
                // A field is its leading blanks and the non-blanks after
                // them, as POSIX has it.
                let mut start = 0;
                for f in 0..=n {
                    start = i;
                    while i < line.len() && blank(line[i]) {
                        i += 1;
                    }
                    while i < line.len() && !blank(line[i]) {
                        i += 1;
                    }
                    if i == line.len() && f < n {
                        return (line.len(), line.len());
                    }
                }
                (start, i)
            }
        }
    }

    /// The part of `line` the comparison looks at.
    fn key<'a>(&self, line: &'a [u8]) -> &'a [u8] {
        let mut key = match self.key {
            None => line,
            Some((first, last)) => {
                let (start, _) = self.field(line, first);
                let end = match last {
                    Some(last) => self.field(line, last).1.max(start),
                    None => line.len(),
                };
                &line[start..end]
            }
        };
        if self.blanks || self.numeric {
            while let [b, rest @ ..] = key {
                if !blank(*b) {
                    break;
                }
                key = rest;
            }
        }
        key
    }

    fn keys(&self, a: &[u8], b: &[u8]) -> Ordering {
        let (a, b) = (self.key(a), self.key(b));
        if self.numeric {
            number(a, b)
        } else if self.fold {
            let up = |c: &u8| c.to_ascii_uppercase();
            a.iter().map(up).cmp(b.iter().map(up))
        } else {
            a.cmp(b)
        }
    }
}

/// A number's sign, its whole digits without leading zeros, and its
/// fraction's digits without trailing zeros.
fn parts(s: &[u8]) -> (bool, &[u8], &[u8]) {
    let (negative, s) = match s {
        [b'-', rest @ ..] => (true, rest),
        [b'+', rest @ ..] => (false, rest),
        _ => (false, s),
    };
    let digits = s.iter().position(|b| !b.is_ascii_digit()).unwrap_or(s.len());
    let mut whole = &s[..digits];
    while let [b'0', rest @ ..] = whole {
        whole = rest;
    }
    let mut fraction: &[u8] = &[];
    if s.get(digits) == Some(&b'.') {
        let s = &s[digits + 1..];
        fraction = &s[..s.iter().position(|b| !b.is_ascii_digit()).unwrap_or(s.len())];
        while let [rest @ .., b'0'] = fraction {
            fraction = rest;
        }
    }
    // -0 is 0.
    (negative && !(whole.is_empty() && fraction.is_empty()), whole, fraction)
}

/// Compare two numbers as written, of any length, with no arithmetic.
fn number(a: &[u8], b: &[u8]) -> Ordering {
    let (an, aw, af) = parts(a);
    let (bn, bw, bf) = parts(b);
    if an != bn {
        return if an { Ordering::Less } else { Ordering::Greater };
    }
    let size = aw.len().cmp(&bw.len()).then_with(|| aw.cmp(bw)).then_with(|| af.cmp(bf));
    if an { size.reverse() } else { size }
}

/// Read what `from` gives into `text`, ending its last line.
fn slurp<R: Read>(from: &mut R, text: &mut Vec<u8>) -> io::Result<()> {
    from.read_to_end(text)?;
    if text.last().is_some_and(|&b| b != b'\n') {
        text.push(b'\n');
    }
    Ok(())
}

/// Sort `v` stably: a merge sort, bottom up, through a second buffer.
/// Smaller than the slice's own sort_by, which is some 12,000 trytes
/// once the comparison is inlined into its many parts.
fn merge_sort<T: Copy, F: Fn(&T, &T) -> Ordering>(v: &mut Vec<T>, less: F) {
    let n = v.len();
    let mut from = v.clone();
    let mut to = v.clone();
    let mut width = 1;
    while width < n {
        let mut start = 0;
        while start < n {
            let mid = (start + width).min(n);
            let end = (start + 2 * width).min(n);
            let (mut i, mut j) = (start, mid);
            for slot in &mut to[start..end] {
                // The left run's line first when equal: stable.
                if j >= end || (i < mid && less(&from[j], &from[i]) != Ordering::Less) {
                    *slot = from[i];
                    i += 1;
                } else {
                    *slot = from[j];
                    j += 1;
                }
            }
            start = end;
        }
        core::mem::swap(&mut from, &mut to);
        width *= 2;
    }
    *v = from;
}

/// Write each line, with its newline.
fn put<W: Write>(to: &mut W, text: &[u8], lines: &[(usize, usize)]) -> io::Result<()> {
    for &(start, end) in lines {
        to.write_all(&text[start..end + 1])?;
    }
    to.flush()
}

fn usage() -> i32 {
    Line::new()
        .str("usage: sort [-bfnru] [-t C] [-k N[,M]] [-o FILE] [FILE]...")
        .eprint();
    2
}

/// A field number of -k, from 1, as an index from 0, with the letters
/// after it (`2n`), which set those options for the whole sort.
fn field_number(s: &str, order: &mut Order) -> Option<usize> {
    let digits = s.bytes().take_while(u8::is_ascii_digit).count();
    // A position in the field (N.C) is not taken: say so rather than
    // sort by something else.
    if digits == 0 || digits > 4 {
        return None;
    }
    for c in s[digits..].bytes() {
        match c {
            b'b' => order.blanks = true,
            b'f' => order.fold = true,
            b'n' => order.numeric = true,
            b'r' => order.reverse = true,
            _ => return None,
        }
    }
    let n = s[..digits].bytes().fold(0, |n, b| n * 10 + (b - b'0') as usize);
    n.checked_sub(1)
}

fn key_option(s: &str, order: &mut Order) -> Option<(usize, Option<usize>)> {
    match s.split_once(',') {
        Some((first, last)) => Some((field_number(first, order)?, Some(field_number(last, order)?))),
        None => Some((field_number(s, order)?, None)),
    }
}

fn run() -> i32 {
    let mut order = Order::default();
    let mut output: Option<&str> = None;
    let mut files: Vec<&str> = Vec::new();
    let mut args = env::args().skip(1);
    let mut options = true;
    while let Some(arg) = args.next() {
        if !options || arg == "-" || !arg.starts_with('-') {
            files.push(arg);
            continue;
        }
        if arg == "--" {
            options = false;
            continue;
        }
        for (i, c) in arg.bytes().enumerate().skip(1) {
            match c {
                b'b' => order.blanks = true,
                b'f' => order.fold = true,
                b'n' => order.numeric = true,
                b'r' => order.reverse = true,
                b'u' => order.unique = true,
                b't' | b'k' | b'o' => {
                    // The value is the rest of the argument, or the next.
                    let value = match &arg[i + 1..] {
                        "" => match args.next() {
                            Some(v) => v,
                            None => return usage(),
                        },
                        rest => rest,
                    };
                    match c {
                        b't' if value.len() == 1 => order.sep = Some(value.as_bytes()[0]),
                        b'k' => match key_option(value, &mut order) {
                            Some(key) => order.key = Some(key),
                            None => return usage(),
                        },
                        b'o' => output = Some(value),
                        _ => return usage(),
                    }
                    break;
                }
                _ => return usage(),
            }
        }
    }
    if files.is_empty() {
        files.push("-");
    }

    let mut text = Vec::new();
    for name in files {
        let read = if name == "-" {
            slurp(&mut io::stdin(), &mut text)
        } else {
            File::open(name).and_then(|mut f| slurp(&mut f, &mut text))
        };
        if let Err(e) = read {
            Line::new().str("sort: ").str(name).str(": ").error(&e).eprint();
            return 2;
        }
    }

    // Each line as where it starts and ends in text, its newline left out.
    let mut lines: Vec<(usize, usize)> = Vec::new();
    let mut start = 0;
    for (i, &b) in text.iter().enumerate() {
        if b == b'\n' {
            lines.push((start, i));
            start = i + 1;
        }
    }
    let line = |&(s, e): &(usize, usize)| &text[s..e];
    let compare = |a: &(usize, usize), b: &(usize, usize)| {
        let (a, b) = (line(a), line(b));
        let mut by = order.keys(a, b);
        if by == Ordering::Equal && !order.unique {
            by = a.cmp(b);
        }
        if order.reverse { by.reverse() } else { by }
    };
    merge_sort(&mut lines, compare);
    if order.unique {
        lines.dedup_by(|b, a| order.keys(line(a), line(b)) == Ordering::Equal);
    }

    let written = match output {
        Some(name) => File::create(name).and_then(|mut f| put(&mut f, &text, &lines)),
        None => put(&mut io::stdout(), &text, &lines),
    };
    if let Err(e) = written {
        Line::new().str("sort: ").str(output.unwrap_or("standard output")).str(": ").error(&e).eprint();
        return 2;
    }
    0
}
