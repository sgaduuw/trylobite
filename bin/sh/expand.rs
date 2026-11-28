//! Expanding a word as typed into the arguments it stands for: its
//! quoting undone, its parameters, commands and sums replaced by their
//! values, and its patterns by the files they match.
//!
//! In '...' every character is itself. In "..." too, but that $ still
//! expands, and \ makes the $, ", \ after it itself. Elsewhere \ makes
//! the next character itself (and is itself at the end of the line).
//! Quotes join with what touches them, and a word of quotes alone ("" or
//! '') is an empty argument.
//!
//! $NAME and ${NAME} are the variable's value, nothing if it is not set;
//! ${NAME:-WORD} is WORD if it is unset or empty, ${NAME-WORD} if it is
//! unset, ${NAME:=WORD} also sets it, and ${#NAME} is its length. $? is
//! the last command's status, $$ the shell's process number, $! the
//! last background job's, $0 the shell's or script's name, $1 to $9
//! (and ${10} on) the positional parameters, $# how many there are, and
//! $@ and $* all of them ("$@" one argument each). $(LIST) is what LIST
//! prints, less the newlines it ends with, and $((SUM)) the sum's value
//! (sh/arith.rs). A ~ starting a word, alone or before a /, is $HOME.
//!
//! Outside double quotes a value is split at spaces, tabs and newlines
//! into several arguments, and one that is empty or all spaces makes
//! none, as in a Unix shell. Then an argument holding an unquoted *, ?
//! or [ is a pattern (sh/glob.rs), replaced by the paths it matches, in
//! order, or kept as it is when none does.

use trystd::prelude::*;

use crate::vars::is_name;
use crate::{Shell, glob};

/// An argument, and the spaces typed before the word it came from.
#[derive(Clone)]
pub struct Arg {
    pub text: Vec<u8>,
    pub gap: u8,
}

/// What a word becomes, piece by piece: each argument's characters, and
/// for each whether it was quoted (so not a pattern's).
struct Fields {
    done: Vec<(Vec<u8>, Vec<bool>)>,
    cur: Vec<u8>,
    quoted: Vec<bool>,
    /// The current argument exists even if empty: something quoted, or
    /// characters, went into it.
    real: bool,
}

impl Fields {
    fn new() -> Fields {
        Fields { done: Vec::new(), cur: Vec::new(), quoted: Vec::new(), real: false }
    }

    fn push(&mut self, c: u8, quoted: bool) {
        self.cur.push(c);
        self.quoted.push(quoted);
        self.real = true;
    }

    fn push_all(&mut self, s: &[u8], quoted: bool) {
        for &c in s {
            self.push(c, quoted);
        }
    }

    fn end(&mut self) {
        if self.real {
            let cur = core::mem::take(&mut self.cur);
            let quoted = core::mem::take(&mut self.quoted);
            self.done.push((cur, quoted));
            self.real = false;
        }
    }

    /// A value from outside quotes: split at blanks.
    fn split(&mut self, value: &[u8]) {
        for &c in value {
            if matches!(c, b' ' | b'\t' | b'\n') {
                self.end();
            } else {
                self.push(c, false);
            }
        }
    }
}

/// What a $ came to.
enum Value {
    /// Not an expansion: the $ is itself.
    Literal,
    Text(Vec<u8>),
    /// $@ or $*: the positional parameters, each its own.
    Params,
}

impl Shell {
    /// The arguments word `word` (as typed) stands for: none, one or more.
    pub fn expand(&mut self, word: &[u8]) -> Vec<Vec<u8>> {
        if word == b"\"$@\"" && self.params.is_empty() {
            return Vec::new(); // "$@" with none is no argument at all
        }
        let mut f = Fields::new();
        self.expand_into(word, &mut f, true);
        f.end();
        let mut out = Vec::new();
        for (text, quoted) in f.done {
            let pattern = text.iter().zip(&quoted).any(|(&c, &q)| !q && matches!(c, b'*' | b'?' | b'['));
            if pattern {
                let found = glob::expand(&text, &quoted);
                if !found.is_empty() {
                    out.extend(found);
                    continue;
                }
            }
            out.push(text);
        }
        out
    }

    /// The one argument `word` stands for, values unsplit and no
    /// patterns: what a variable's value is, or a case's word.
    pub fn expand_one(&mut self, word: &[u8]) -> Vec<u8> {
        self.expand_quoted(word).0
    }

    /// The same, with which characters were quoted: a case pattern.
    pub fn expand_quoted(&mut self, word: &[u8]) -> (Vec<u8>, Vec<bool>) {
        let mut f = Fields::new();
        self.expand_into(word, &mut f, false);
        // Unsplit, it is one argument, but $@ may have ended several.
        let mut text = Vec::new();
        let mut quoted = Vec::new();
        for (t, q) in f.done {
            text.extend(t);
            text.push(b' ');
            quoted.extend(q);
            quoted.push(true);
        }
        text.extend(f.cur);
        quoted.extend(f.quoted);
        (text, quoted)
    }

    fn expand_into(&mut self, word: &[u8], f: &mut Fields, split: bool) {
        let mut i = 0;
        if word.first() == Some(&b'~') && matches!(word.get(1), None | Some(b'/')) {
            let home = self.vars.get(b"HOME").unwrap_or(b"").to_vec();
            f.push_all(&home, true);
            f.real = true;
            i = 1;
        }
        let mut quote = 0;
        while i < word.len() {
            let c = word[i];
            i += 1;
            match (quote, c) {
                (b'\'', b'\'') | (b'"', b'"') => quote = 0,
                (b'\'', _) => f.push(c, true),
                (0, b'\'' | b'"') => {
                    quote = c;
                    f.real = true;
                }
                (0, b'\\') => match word.get(i) {
                    Some(&next) => {
                        f.push(next, true);
                        i += 1;
                    }
                    None => f.push(c, true),
                },
                (b'"', b'\\') if matches!(word.get(i), Some(b'$' | b'"' | b'\\' | b'`')) => {
                    f.push(word[i], true);
                    i += 1;
                }
                (_, b'$') => {
                    let (value, used) = self.dollar(&word[i..]);
                    i += used;
                    let quoted = quote != 0;
                    match value {
                        Value::Literal => f.push(b'$', true),
                        Value::Text(v) => {
                            if !quoted && split {
                                f.split(&v);
                            } else {
                                f.push_all(&v, quoted);
                            }
                        }
                        Value::Params => {
                            let params = self.params.clone();
                            for (k, p) in params.iter().enumerate() {
                                if k > 0 {
                                    f.end(); // an argument each
                                }
                                if !quoted && split {
                                    f.split(p);
                                } else {
                                    f.push_all(p, quoted);
                                }
                            }
                        }
                    }
                }
                _ => f.push(c, quote != 0),
            }
        }
    }

    /// What the $ before `rest` stands for, and how much of `rest` it
    /// takes.
    fn dollar(&mut self, rest: &[u8]) -> (Value, usize) {
        let Some(&c) = rest.first() else {
            return (Value::Literal, 0);
        };
        match c {
            b'{' => {
                let Some(close) = rest.iter().position(|&c| c == b'}') else {
                    return (Value::Literal, 0); // the lexer has seen to this
                };
                (self.braced(&rest[1..close]), close + 1)
            }
            b'(' => {
                let Ok(end) = crate::lex::closing(rest, 0) else {
                    return (Value::Literal, 0);
                };
                if rest.get(1) == Some(&b'(') && rest[end - 2] == b')' {
                    let sum = self.expand_one(&rest[2..end - 2]);
                    return (Value::Text(self.arith(&sum)), end);
                }
                (Value::Text(self.substitute(&rest[1..end - 1])), end)
            }
            b'@' | b'*' => (Value::Params, 1),
            _ => {
                if let Some(v) = self.special(c) {
                    return (Value::Text(v), 1);
                }
                let n = rest.iter().take_while(|&&c| c.is_ascii_alphanumeric() || c == b'_').count();
                if n == 0 || rest[0].is_ascii_digit() {
                    return (Value::Literal, 0);
                }
                (Value::Text(self.lookup(&rest[..n]).unwrap_or_default()), n)
            }
        }
    }

    /// ${...}: NAME, NAME:-WORD, NAME-WORD, NAME:=WORD, NAME=WORD or #NAME.
    fn braced(&mut self, inner: &[u8]) -> Value {
        if let Some(name) = inner.strip_prefix(b"#") {
            if !name.is_empty() {
                let n = self.lookup(name).map_or(0, |v| v.len());
                return Value::Text(number(n as i32));
            }
        }
        let n = inner.iter().take_while(|&&c| c.is_ascii_alphanumeric() || c == b'_').count();
        let n = if n == 0 && !inner.is_empty() { 1 } else { n }; // ${?}, ${#}
        let (name, rest) = inner.split_at(n);
        if name == b"@" || name == b"*" {
            return Value::Params;
        }
        let value = self.lookup(name);
        let (op, word) = match rest {
            [] => return Value::Text(value.unwrap_or_default()),
            [b':', op, word @ ..] => ((*op, true), word),
            [op, word @ ..] => ((*op, false), word),
        };
        let missing = value.as_ref().is_none_or(|v| op.1 && v.is_empty());
        match op.0 {
            b'-' if missing => Value::Text(self.expand_one(word)),
            b'=' if missing => {
                let v = self.expand_one(word);
                if is_name(name) {
                    self.vars.set(name, &v);
                }
                Value::Text(v)
            }
            b'+' => Value::Text(if missing { Vec::new() } else { self.expand_one(word) }),
            b'-' | b'=' => Value::Text(value.unwrap_or_default()),
            _ => Value::Literal, // not a form the shell knows
        }
    }

    /// A variable's value, or a special or positional parameter's.
    pub fn lookup(&self, name: &[u8]) -> Option<Vec<u8>> {
        if let [c] = name {
            if let Some(v) = self.special(*c) {
                return Some(v);
            }
        }
        if !name.is_empty() && name.iter().all(u8::is_ascii_digit) {
            let k: usize = name.iter().fold(0, |n, &c| n.saturating_mul(10).saturating_add((c - b'0') as usize));
            return self.params.get(k.wrapping_sub(1)).cloned();
        }
        if !is_name(name) {
            return None;
        }
        self.vars.get(name).map(|v| v.to_vec())
    }

    /// $?, $$, $!, $#, $0 and $1 to $9.
    fn special(&self, c: u8) -> Option<Vec<u8>> {
        match c {
            b'?' => Some(number(self.status)),
            b'$' => Some(number(trystd::process::id() as i32)),
            b'!' => Some(self.last_bg.map(|p| number(p as i32)).unwrap_or_default()),
            b'#' => Some(number(self.params.len() as i32)),
            b'0' => Some(self.arg0.clone()),
            b'1'..=b'9' => Some(self.params.get((c - b'1') as usize).cloned().unwrap_or_default()),
            _ => None,
        }
    }
}

/// `n` in decimal.
pub fn number(n: i32) -> Vec<u8> {
    number64(n as i64)
}

pub fn number64(n: i64) -> Vec<u8> {
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
