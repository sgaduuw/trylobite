//! Lexing: a line into words and operators.
//!
//! A word is characters up to an unquoted space, tab, |, < or >; each of
//! those operators is a token of its own, and >> one too. A word keeps
//! its quotes, backslashes and $ as typed: what they mean is worked out
//! when the command runs (sh/expand.rs), since a variable's value can
//! change between lexing and running. The lexer only needs to know
//! where quoting starts and stops: in '...' every character is itself,
//! in "..." too but that \ keeps the character after it inside, and
//! elsewhere \ keeps the next character in the word. ${...} is part of
//! the word whatever it holds, up to its }.
//!
//! Each word keeps how many spaces came before it, so that `write` can
//! give its text back as typed.

use trystd::prelude::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Word,
    /// |
    Pipe,
    /// < PATH
    In,
    /// > PATH
    Out,
    /// >> PATH
    Append,
}

#[derive(Clone)]
pub struct Tok {
    pub kind: Kind,
    /// A word's characters as typed, quotes and all.
    pub text: Vec<u8>,
    /// Spaces before it, as typed.
    pub gap: u8,
}

/// A quote, or a ${, that was not closed.
pub struct Unclosed;

/// Whether `c` ends a word, unquoted.
fn ends_word(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'|' | b'<' | b'>')
}

pub fn lex(line: &[u8]) -> Result<Vec<Tok>, Unclosed> {
    let mut toks = Vec::new();
    let mut i = 0;
    loop {
        let mut gap = 0u8;
        while i < line.len() && matches!(line[i], b' ' | b'\t') {
            gap = gap.saturating_add(1);
            i += 1;
        }
        if i == line.len() {
            return Ok(toks);
        }
        let start = i;
        let kind = match line[i] {
            b'|' => Kind::Pipe,
            b'<' => Kind::In,
            b'>' if line.get(i + 1) == Some(&b'>') => {
                i += 1;
                Kind::Append
            }
            b'>' => Kind::Out,
            _ => Kind::Word,
        };
        if kind != Kind::Word {
            i += 1;
            toks.push(Tok { kind, text: Vec::new(), gap });
            continue;
        }
        i = word_end(line, i)?;
        toks.push(Tok { kind, text: line[start..i].to_vec(), gap });
    }
}

/// Where the word starting at `i` ends: past its last character.
fn word_end(line: &[u8], mut i: usize) -> Result<usize, Unclosed> {
    let mut quote = 0;
    while i < line.len() {
        let c = line[i];
        if quote == b'\'' {
            if c == b'\'' {
                quote = 0;
            }
            i += 1;
            continue;
        }
        if quote == 0 && ends_word(c) {
            break;
        }
        match c {
            b'\\' => i += 1, // the next character, if any, is kept
            b'"' if quote == b'"' => quote = 0,
            b'"' | b'\'' if quote == 0 => quote = c,
            b'$' if line.get(i + 1) == Some(&b'{') => {
                match line[i..].iter().position(|&c| c == b'}') {
                    Some(k) => i += k,
                    None => return Err(Unclosed),
                }
            }
            _ => {}
        }
        i += 1;
    }
    if quote != 0 {
        return Err(Unclosed);
    }
    Ok(i.min(line.len()))
}
