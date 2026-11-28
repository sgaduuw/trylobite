//! Lexing: a typed line into tokens, its quoting undone.
//!
//! A word is characters up to an unquoted space, |, < or >; each of
//! those operators is a token of its own, and >> one too. In '...' every
//! character is itself; in "..." too, but that \" and \\ stand for " and
//! \; elsewhere \ makes the character after it itself (and is itself at
//! the end of the line). Quotes join with what touches them, and a word
//! of quotes alone ("" or '') is an empty word.
//!
//! Each word keeps how many spaces came before it, so that `write` can
//! give its text back as typed. New operators (; && || &) and what
//! expansions need (which characters were quoted) go here.

use crate::LINE_MAX;

/// A line has at most one token per character.
pub const TOKS: usize = LINE_MAX;

#[derive(Clone, Copy, PartialEq, Eq)]
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

#[derive(Clone, Copy)]
pub struct Tok {
    pub kind: Kind,
    /// A word's characters, in `Lexed::text`.
    start: u8,
    len: u8,
    /// Spaces before it, as typed.
    pub gap: u8,
}

pub struct Lexed {
    text: [u8; LINE_MAX],
    toks: [Tok; TOKS],
    pub n: usize,
}

/// A quote that was not closed.
pub struct Unclosed;

impl Lexed {
    pub fn tok(&self, k: usize) -> Tok {
        self.toks[k]
    }

    /// The characters of word `k`, its quoting undone.
    pub fn word(&self, k: usize) -> &[u8] {
        let t = self.toks[k];
        &self.text[t.start as usize..(t.start + t.len) as usize]
    }

    pub fn lex(line: &[u8]) -> Result<Lexed, Unclosed> {
        let none = Tok { kind: Kind::Word, start: 0, len: 0, gap: 0 };
        let mut lx = Lexed { text: [0; LINE_MAX], toks: [none; TOKS], n: 0 };
        let mut t = 0; // where the next word character goes
        let mut i = 0;
        loop {
            let mut gap = 0;
            while i < line.len() && line[i] == b' ' {
                gap += 1;
                i += 1;
            }
            if i == line.len() {
                return Ok(lx);
            }
            let start = t;
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
            } else {
                let mut quote = 0;
                while i < line.len() {
                    let c = line[i];
                    i += 1;
                    let kept = if quote == 0 {
                        match c {
                            b' ' | b'|' | b'<' | b'>' => {
                                i -= 1;
                                break;
                            }
                            b'\'' | b'"' => {
                                quote = c;
                                continue;
                            }
                            b'\\' if i < line.len() => {
                                i += 1;
                                line[i - 1]
                            }
                            _ => c,
                        }
                    } else if c == quote {
                        quote = 0;
                        continue;
                    } else if quote == b'"'
                        && c == b'\\'
                        && matches!(line.get(i), Some(b'"' | b'\\'))
                    {
                        i += 1;
                        line[i - 1]
                    } else {
                        c
                    };
                    lx.text[t] = kept;
                    t += 1;
                }
                if quote != 0 {
                    return Err(Unclosed);
                }
            }
            lx.toks[lx.n] = Tok { kind, start: start as u8, len: (t - start) as u8, gap };
            lx.n += 1;
        }
    }
}
