//! Writes `layout.rs`: every `.equ NAME, EXPR` of include/layout.s that
//! is worked out from numbers and earlier names with + - * and
//! parentheses, as a Rust constant, so that the library repeats none of
//! the kernel's numbers (AGENTS.md). One that fits an i32 is an i32, any
//! other an i64; one that needs a name from a build (such as NPROG) is
//! left out.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::Path;

fn main() {
    let layout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../include/layout.s");
    println!("cargo::rerun-if-changed={}", layout.display());
    let text = std::fs::read_to_string(&layout).expect("include/layout.s");
    let mut names: HashMap<String, i64> = HashMap::new();
    let mut out = String::from("// Written by build.rs from include/layout.s.\n");
    for line in text.lines() {
        let Some(rest) = line.trim_start().strip_prefix(".equ") else {
            continue;
        };
        let rest = rest.split('#').next().unwrap_or("");
        let Some((name, expr)) = rest.split_once(',') else {
            continue;
        };
        let name = name.trim();
        let mut p = Parser {
            s: expr.trim().as_bytes(),
            i: 0,
            names: &names,
        };
        let Some(value) = p.expr().filter(|_| p.done()) else {
            continue;
        };
        names.insert(name.to_string(), value);
        let ty = if i32::try_from(value).is_ok() {
            "i32"
        } else {
            "i64"
        };
        writeln!(out, "pub const {name}: {ty} = {value};").unwrap();
    }
    let dest = Path::new(&std::env::var("OUT_DIR").unwrap()).join("layout.rs");
    std::fs::write(dest, out).unwrap();
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
    names: &'a HashMap<String, i64>,
}

impl Parser<'_> {
    fn skip(&mut self) {
        while self.s.get(self.i).is_some_and(|c| c.is_ascii_whitespace()) {
            self.i += 1;
        }
    }

    fn done(&mut self) -> bool {
        self.skip();
        self.i == self.s.len()
    }

    fn eat(&mut self, c: u8) -> bool {
        self.skip();
        let found = self.s.get(self.i) == Some(&c);
        if found {
            self.i += 1;
        }
        found
    }

    fn expr(&mut self) -> Option<i64> {
        let mut v = self.term()?;
        loop {
            if self.eat(b'+') {
                v = v.checked_add(self.term()?)?;
            } else if self.eat(b'-') {
                v = v.checked_sub(self.term()?)?;
            } else {
                return Some(v);
            }
        }
    }

    fn term(&mut self) -> Option<i64> {
        let mut v = self.unary()?;
        while self.eat(b'*') {
            v = v.checked_mul(self.unary()?)?;
        }
        Some(v)
    }

    fn unary(&mut self) -> Option<i64> {
        if self.eat(b'-') {
            return self.unary()?.checked_neg();
        }
        if self.eat(b'(') {
            let v = self.expr()?;
            return self.eat(b')').then_some(v);
        }
        self.skip();
        let start = self.i;
        while self
            .s
            .get(self.i)
            .is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'_')
        {
            self.i += 1;
        }
        let word = std::str::from_utf8(&self.s[start..self.i]).ok()?;
        match word.parse::<i64>() {
            Ok(n) => Some(n),
            Err(_) => self.names.get(word).copied(),
        }
    }
}
