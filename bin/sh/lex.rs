//! Lexing: text into words and operators.
//!
//! A word is characters up to an unquoted blank, newline or operator
//! character (| & ; < > ( )). The operators are | || & && ; ;; ( ) and
//! the redirections < > >> and >&N, which a single digit just before
//! them (2> errors) makes about that descriptor. A newline is a token of
//! its own, since it ends a command as ; does. A # starting a word, and
//! all after it on its line, is a comment.
//!
//! A word keeps its quotes, backslashes and $ as typed: what they mean
//! is worked out when the command runs (sh/expand.rs), since a
//! variable's value can change between lexing and running. The lexer
//! only finds where each ends: in '...' every character is itself, in
//! "..." too but that \ keeps the character after it inside, and
//! elsewhere \ keeps the next character in the word (and a \ before a
//! newline joins the lines). ${...}, $(...) and $((...)) are part of the
//! word whatever they hold, to the bracket that closes them.
//!
//! Each word keeps how many spaces came before it, so that `write` can
//! give its text back as typed, and its line, for errors in scripts.

use trystd::prelude::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Word,
    Newline,
    /// |
    Pipe,
    /// ||
    OrIf,
    /// &
    Amp,
    /// &&
    AndIf,
    /// ;
    Semi,
    /// ;;
    DSemi,
    LParen,
    RParen,
    /// < PATH, > PATH, >> PATH, or >&N with the N as the token's text:
    /// `fd` says which descriptor.
    Redir(Redir),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Redir {
    In,
    Out,
    Append,
    /// >&N or <&N: a copy of descriptor N.
    Dup,
}

#[derive(Clone, Debug)]
pub struct Tok {
    pub kind: Kind,
    /// A word's characters as typed, quotes and all; >&N's N.
    pub text: Vec<u8>,
    /// Spaces before it, as typed.
    pub gap: u8,
    /// A redirection's descriptor.
    pub fd: i8,
    /// The line it is on, from 1.
    pub line: u32,
}

impl Tok {
    /// Whether this is the plain word `w`: unquoted, so a reserved word
    /// where one may stand.
    pub fn is(&self, w: &[u8]) -> bool {
        self.kind == Kind::Word && self.text == w
    }
}

/// A quote, or a ${, $( or $((, that was not closed: more lines may
/// close it.
pub struct Unclosed;

/// Whether `c` ends a word, unquoted.
fn ends_word(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'|' | b'&' | b';' | b'<' | b'>' | b'(' | b')')
}

pub fn lex(src: &[u8]) -> Result<Vec<Tok>, Unclosed> {
    let mut toks: Vec<Tok> = Vec::new();
    let mut i = 0;
    let mut line = 1;
    loop {
        let mut gap = 0u8;
        loop {
            match src.get(i) {
                Some(b' ' | b'\t') => gap = gap.saturating_add(1),
                // A \ ending a line joins it to the next.
                Some(b'\\') if src.get(i + 1) == Some(&b'\n') => {
                    i += 1;
                    line += 1;
                }
                _ => break,
            }
            i += 1;
        }
        let Some(&c) = src.get(i) else {
            return Ok(toks);
        };
        let tok = |kind, text: &[u8], fd| Tok { kind, text: text.to_vec(), gap, fd, line };
        let next = src.get(i + 1).copied();
        // A digit before < or > names the descriptor it redirects.
        let (fd, at) = if c.is_ascii_digit() && matches!(next, Some(b'<' | b'>')) {
            ((c - b'0') as i8, i + 1)
        } else {
            (-1, i)
        };
        let op = src[at];
        let after = src.get(at + 1).copied();
        let (kind, len) = match op {
            b'\n' => (Kind::Newline, 1),
            b'#' => {
                // A comment, to the line's end.
                while i < src.len() && src[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'|' if after == Some(b'|') => (Kind::OrIf, 2),
            b'|' => (Kind::Pipe, 1),
            b'&' if after == Some(b'&') => (Kind::AndIf, 2),
            b'&' => (Kind::Amp, 1),
            b';' if after == Some(b';') => (Kind::DSemi, 2),
            b';' => (Kind::Semi, 1),
            b'(' => (Kind::LParen, 1),
            b')' => (Kind::RParen, 1),
            b'<' | b'>' if after == Some(b'&') => {
                // >&N: the N is one digit.
                let n = src.get(at + 2).copied().filter(u8::is_ascii_digit);
                let Some(n) = n else {
                    toks.push(tok(Kind::Redir(Redir::Dup), b"", if fd < 0 { (op == b'>') as i8 } else { fd }));
                    i = at + 2;
                    continue;
                };
                let fd = if fd < 0 { (op == b'>') as i8 } else { fd };
                toks.push(tok(Kind::Redir(Redir::Dup), &[n], fd));
                i = at + 3;
                continue;
            }
            b'<' => (Kind::Redir(Redir::In), 1),
            b'>' if after == Some(b'>') => (Kind::Redir(Redir::Append), 2),
            b'>' => (Kind::Redir(Redir::Out), 1),
            _ => (Kind::Word, 0),
        };
        if kind != Kind::Word {
            let fd = match kind {
                Kind::Redir(Redir::In) if fd < 0 => 0,
                Kind::Redir(_) if fd < 0 => 1,
                _ => fd,
            };
            toks.push(tok(kind, b"", fd));
            if kind == Kind::Newline {
                line += 1;
            }
            i = at + len;
            continue;
        }
        let start = i;
        let (end, lines) = word_end(src, i)?;
        toks.push(Tok { kind, text: src[start..end].to_vec(), gap, fd: -1, line });
        line += lines;
        i = end;
    }
}

/// Where the word starting at `i` ends, past its last character, and
/// how many newlines it holds.
fn word_end(src: &[u8], mut i: usize) -> Result<(usize, u32), Unclosed> {
    let mut lines = 0;
    let mut quote = 0;
    while i < src.len() {
        let c = src[i];
        if c == b'\n' {
            lines += 1;
        }
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
            b'\\' => {
                if src.get(i + 1) == Some(&b'\n') {
                    lines += 1;
                }
                i += 1; // the next character, if any, is kept
            }
            b'"' if quote == b'"' => quote = 0,
            b'"' | b'\'' if quote == 0 => quote = c,
            b'$' if matches!(src.get(i + 1), Some(b'{' | b'(')) => {
                let end = closing(src, i + 1)?;
                lines += src[i..end].iter().filter(|&&c| c == b'\n').count() as u32;
                i = end;
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    if quote != 0 {
        return Err(Unclosed);
    }
    Ok((i.min(src.len()), lines))
}

/// Past the bracket that closes the { or ( at `open`, skipping what is
/// quoted or nested inside.
pub fn closing(src: &[u8], open: usize) -> Result<usize, Unclosed> {
    let (o, c) = if src[open] == b'{' { (b'{', b'}') } else { (b'(', b')') };
    let mut depth = 0;
    let mut i = open;
    let mut quote = 0;
    while i < src.len() {
        let ch = src[i];
        i += 1;
        if quote == b'\'' {
            if ch == b'\'' {
                quote = 0;
            }
            continue;
        }
        match ch {
            b'\\' => i += 1,
            b'"' if quote == b'"' => quote = 0,
            b'"' => quote = ch,
            b'\'' if quote == 0 => quote = ch,
            _ if quote != 0 => {}
            _ if ch == o => depth += 1,
            _ if ch == c => {
                depth -= 1;
                if depth == 0 {
                    return Ok(i);
                }
            }
            _ => {}
        }
    }
    Err(Unclosed)
}
