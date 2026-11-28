//! Arithmetic, $((SUM)): whole numbers (64-bit) with C's operators and
//! precedence, as a Unix shell has them: unary - + ! ~, then * / %, + -,
//! << >>, < <= > >=, == !=, &, ^, |, &&, ||, and parentheses. A name is
//! its variable's value, read as a number, 0 if it is unset or empty;
//! NAME = SUM sets it. Division by 0 is an error, and so is anything that
//! is not a sum: the shell says so and the value is 0.

use trystd::prelude::*;

use crate::Shell;
use crate::expand::number64;
use crate::out::Out;

struct Sum<'a> {
    text: &'a [u8],
    at: usize,
    failed: Option<&'static [u8]>,
}

impl Shell {
    /// The value of `sum`, its $ expansions done already, in decimal.
    pub fn arith(&mut self, sum: &[u8]) -> Vec<u8> {
        let mut s = Sum { text: sum, at: 0, failed: None };
        let v = self.assign(&mut s);
        s.blanks();
        if s.failed.is_none() && s.at < sum.len() {
            s.failed = Some(b"not a sum");
        }
        if let Some(why) = s.failed {
            Out::err().b(b"sh: $((").b(sum).b(b")): ").b(why).nl();
            return b"0".to_vec();
        }
        number64(v)
    }

    /// NAME = SUM, or a sum.
    fn assign(&mut self, s: &mut Sum) -> i64 {
        s.blanks();
        let start = s.at;
        let name = s.name();
        s.blanks();
        if !name.is_empty() && s.peek() == Some(b'=') && s.text.get(s.at + 1) != Some(&b'=') {
            s.at += 1;
            let v = self.assign(s);
            let name = name.to_vec();
            self.vars.set(&name, &number64(v));
            return v;
        }
        s.at = start;
        self.binary(s, 0)
    }

    /// Operators of precedence `min` and above, left to right.
    fn binary(&mut self, s: &mut Sum, min: u8) -> i64 {
        let mut left = self.unary(s);
        loop {
            s.blanks();
            let Some((op, prec, len)) = s.operator() else { return left };
            if prec < min {
                return left;
            }
            s.at += len;
            // && and || skip the right side's assignments when settled.
            let right = self.binary(s, prec + 1);
            left = match op {
                b"*" => left.wrapping_mul(right),
                b"/" | b"%" => {
                    if right == 0 {
                        s.failed.get_or_insert(b"division by 0");
                        0
                    } else if op == b"/" {
                        left.wrapping_div(right)
                    } else {
                        left.wrapping_rem(right)
                    }
                }
                b"+" => left.wrapping_add(right),
                b"-" => left.wrapping_sub(right),
                b"<<" => left.wrapping_shl(right as u32),
                b">>" => left.wrapping_shr(right as u32),
                b"<" => (left < right) as i64,
                b"<=" => (left <= right) as i64,
                b">" => (left > right) as i64,
                b">=" => (left >= right) as i64,
                b"==" => (left == right) as i64,
                b"!=" => (left != right) as i64,
                b"&" => left & right,
                b"^" => left ^ right,
                b"|" => left | right,
                b"&&" => (left != 0 && right != 0) as i64,
                _ => (left != 0 || right != 0) as i64,
            };
        }
    }

    fn unary(&mut self, s: &mut Sum) -> i64 {
        s.blanks();
        match s.peek() {
            Some(b'-') => {
                s.at += 1;
                self.unary(s).wrapping_neg()
            }
            Some(b'+') => {
                s.at += 1;
                self.unary(s)
            }
            Some(b'!') => {
                s.at += 1;
                (self.unary(s) == 0) as i64
            }
            Some(b'~') => {
                s.at += 1;
                !self.unary(s)
            }
            Some(b'(') => {
                s.at += 1;
                let v = self.assign(s);
                s.blanks();
                if s.peek() == Some(b')') {
                    s.at += 1;
                } else {
                    s.failed.get_or_insert(b"a ( is not closed");
                }
                v
            }
            Some(c) if c.is_ascii_digit() => {
                let mut v: i64 = 0;
                while let Some(c) = s.peek().filter(u8::is_ascii_digit) {
                    v = v.wrapping_mul(10).wrapping_add((c - b'0') as i64);
                    s.at += 1;
                }
                v
            }
            Some(c) if c.is_ascii_alphabetic() || c == b'_' => {
                let name = s.name().to_vec();
                let value = self.vars.get(&name).unwrap_or(b"").to_vec();
                let text = value.trim_ascii();
                if text.is_empty() {
                    return 0;
                }
                match crate::builtin::parse_number64(text) {
                    Some(v) => v,
                    None => {
                        s.failed.get_or_insert(b"a variable is not a number");
                        0
                    }
                }
            }
            _ => {
                s.failed.get_or_insert(b"not a sum");
                0
            }
        }
    }
}

impl Sum<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.get(self.at).copied()
    }

    fn blanks(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n')) {
            self.at += 1;
        }
    }

    fn name(&mut self) -> &[u8] {
        let start = self.at;
        if self.peek().is_some_and(|c| c.is_ascii_alphabetic() || c == b'_') {
            while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == b'_') {
                self.at += 1;
            }
        }
        &self.text[start..self.at]
    }

    /// The binary operator here: its text, precedence and length.
    fn operator(&self) -> Option<(&'static [u8], u8, usize)> {
        const OPS: &[(&[u8], u8)] = &[
            (b"||", 1),
            (b"&&", 2),
            (b"==", 6),
            (b"!=", 6),
            (b"<=", 7),
            (b">=", 7),
            (b"<<", 8),
            (b">>", 8),
            (b"|", 3),
            (b"^", 4),
            (b"&", 5),
            (b"<", 7),
            (b">", 7),
            (b"+", 9),
            (b"-", 9),
            (b"*", 10),
            (b"/", 10),
            (b"%", 10),
        ];
        let rest = &self.text[self.at..];
        OPS.iter().find(|(op, _)| rest.starts_with(op)).map(|&(op, p)| (op, p, op.len()))
    }
}
