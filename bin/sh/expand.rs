//! Expanding a word as typed into the arguments it stands for: its
//! quoting undone and its variables replaced by their values.
//!
//! In '...' every character is itself. In "..." too, but that $ still
//! expands, and \ makes the $, ", \ after it itself. Elsewhere \ makes
//! the next character itself (and is itself at the end of the line).
//! Quotes join with what touches them, and a word of quotes alone ("" or
//! '') is an empty argument.
//!
//! $NAME and ${NAME} are the variable's value, nothing if it is not set;
//! ${NAME:-WORD} is WORD if it is unset or empty, ${NAME-WORD} if it is
//! unset, and ${#NAME} its length. $? is the last command's status, $$
//! the shell's process number. A ~ starting a word, alone or before a /,
//! is $HOME. Outside double quotes a value is split at spaces, tabs and
//! newlines into several arguments, and one that is empty or all spaces
//! makes none, as in a Unix shell; inside them it is one argument
//! whatever it holds.

use trystd::prelude::*;

use crate::Shell;
use crate::vars::is_name;

/// An argument, and the spaces typed before the word it came from.
#[derive(Clone)]
pub struct Arg {
    pub text: Vec<u8>,
    pub gap: u8,
}

/// What a word becomes, piece by piece.
struct Fields {
    done: Vec<Vec<u8>>,
    cur: Vec<u8>,
    /// The current argument exists even if empty: something quoted, or
    /// characters, went into it.
    real: bool,
}

impl Fields {
    fn push(&mut self, c: u8) {
        self.cur.push(c);
        self.real = true;
    }

    fn end(&mut self) {
        if self.real {
            self.done.push(core::mem::take(&mut self.cur));
            self.real = false;
        }
    }

    /// A value from outside quotes: split at blanks.
    fn split(&mut self, value: &[u8]) {
        for &c in value {
            if matches!(c, b' ' | b'\t' | b'\n') {
                self.end();
            } else {
                self.push(c);
            }
        }
    }
}

impl Shell {
    /// The arguments word `word` (as typed) stands for: none, one or more.
    pub fn expand(&self, word: &[u8]) -> Vec<Vec<u8>> {
        let mut f = Fields { done: Vec::new(), cur: Vec::new(), real: false };
        self.expand_into(word, &mut f, true);
        f.end();
        f.done
    }

    /// The one argument `word` stands for, values unsplit: what a
    /// variable's value or a redirection's file name is.
    pub fn expand_one(&self, word: &[u8]) -> Vec<u8> {
        let mut f = Fields { done: Vec::new(), cur: Vec::new(), real: false };
        self.expand_into(word, &mut f, false);
        f.cur
    }

    fn expand_into(&self, word: &[u8], f: &mut Fields, split: bool) {
        let mut i = 0;
        if word.first() == Some(&b'~') && matches!(word.get(1), None | Some(b'/')) {
            for &c in self.vars.get(b"HOME").unwrap_or(b"") {
                f.push(c);
            }
            f.real = true;
            i = 1;
        }
        let mut quote = 0;
        while i < word.len() {
            let c = word[i];
            i += 1;
            match (quote, c) {
                (b'\'', b'\'') | (b'"', b'"') => quote = 0,
                (b'\'', _) => f.push(c),
                (0, b'\'' | b'"') => {
                    quote = c;
                    f.real = true;
                }
                (0, b'\\') => match word.get(i) {
                    Some(&next) => {
                        f.push(next);
                        i += 1;
                    }
                    None => f.push(c),
                },
                (b'"', b'\\') if matches!(word.get(i), Some(b'$' | b'"' | b'\\')) => {
                    f.push(word[i]);
                    i += 1;
                }
                (_, b'$') => {
                    let (value, used) = self.dollar(&word[i..]);
                    i += used;
                    match value {
                        Value::Literal => f.push(b'$'),
                        Value::Text(v) => {
                            if quote == 0 && split {
                                f.split(&v);
                            } else {
                                for c in v {
                                    f.push(c);
                                }
                            }
                        }
                    }
                }
                _ => f.push(c),
            }
        }
    }

    /// What the $ before `rest` stands for, and how much of `rest` it
    /// takes.
    fn dollar(&self, rest: &[u8]) -> (Value, usize) {
        let Some(&c) = rest.first() else {
            return (Value::Literal, 0);
        };
        if c == b'{' {
            let Some(close) = rest.iter().position(|&c| c == b'}') else {
                return (Value::Literal, 0); // the lexer has seen to this
            };
            return (self.braced(&rest[1..close]), close + 1);
        }
        if let Some(v) = self.special(c) {
            return (Value::Text(v), 1);
        }
        let n = rest.iter().take_while(|&&c| c.is_ascii_alphanumeric() || c == b'_').count();
        if n == 0 || rest[0].is_ascii_digit() {
            return (Value::Literal, 0);
        }
        (Value::Text(self.lookup(&rest[..n]).unwrap_or_default()), n)
    }

    /// ${...}: NAME, NAME:-WORD, NAME-WORD or #NAME.
    fn braced(&self, inner: &[u8]) -> Value {
        if let Some(name) = inner.strip_prefix(b"#") {
            if !name.is_empty() {
                let n = self.lookup(name).map_or(0, |v| v.len());
                return Value::Text(number(n as i32));
            }
        }
        let n = inner.iter().take_while(|&&c| c.is_ascii_alphanumeric() || c == b'_').count();
        let (name, rest) = if n == 0 && inner.len() == 1 { (inner, &inner[1..]) } else { inner.split_at(n) };
        let value = self.lookup(name);
        let (empty_too, word) = if let Some(w) = rest.strip_prefix(b":-") {
            (true, Some(w))
        } else if let Some(w) = rest.strip_prefix(b"-") {
            (false, Some(w))
        } else if rest.is_empty() {
            (false, None)
        } else {
            return Value::Literal; // not a form the shell knows
        };
        match (value, word) {
            (Some(v), Some(_)) if !(empty_too && v.is_empty()) => Value::Text(v),
            (_, Some(w)) => Value::Text(self.expand_one(w)),
            (v, None) => Value::Text(v.unwrap_or_default()),
        }
    }

    /// A variable's value, or a special parameter's.
    fn lookup(&self, name: &[u8]) -> Option<Vec<u8>> {
        if let [c] = name {
            if let Some(v) = self.special(*c) {
                return Some(v);
            }
        }
        if !is_name(name) {
            return None;
        }
        self.vars.get(name).map(|v| v.to_vec())
    }

    /// $?, $$ and the like.
    fn special(&self, c: u8) -> Option<Vec<u8>> {
        match c {
            b'?' => Some(number(self.status)),
            b'$' => Some(number(trystd::process::id() as i32)),
            _ => None,
        }
    }
}

enum Value {
    /// Not an expansion: the $ is itself.
    Literal,
    Text(Vec<u8>),
}

/// `n` in decimal.
pub fn number(n: i32) -> Vec<u8> {
    let mut v = Vec::new();
    if n < 0 {
        v.push(b'-');
    }
    let mut m = n.unsigned_abs();
    let at = v.len();
    loop {
        v.insert(at, b'0' + (m % 10) as u8);
        m /= 10;
        if m == 0 {
            return v;
        }
    }
}

/// The variable a word as typed assigns, NAME=VALUE: its name and its
/// value as typed, if it is one.
pub fn assignment(word: &[u8]) -> Option<(&[u8], &[u8])> {
    let eq = word.iter().position(|&c| c == b'=')?;
    is_name(&word[..eq]).then(|| (&word[..eq], &word[eq + 1..]))
}
