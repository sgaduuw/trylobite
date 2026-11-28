//! less [FILE]: show a file, or standard input when none is named, a
//! screen at a time, as Unix's less does, small. Long lines wrap; a tab
//! goes to the next multiple of 8, and another control character shows
//! as ^ and a letter. The last row says where you are: the file's name
//! at its start, `:` in its middle, `(END)` once the last line shows.
//!
//!   Space f Ctrl-F PageDown   a screen down       b Ctrl-B PageUp  a screen up
//!   j Enter e Ctrl-N Down     a row down          k y Ctrl-P Up    a row up
//!   d Ctrl-D                  half a screen down  u Ctrl-U         half a screen up
//!   g < Home                  the first line      G > End          the last
//!   /TEXT Enter               the next line holding TEXT, which every
//!   ?TEXT Enter               match on the screen shows in reverse;
//!   n N                       ? looks back; n again, N the other way
//!   r Ctrl-L                  draw the screen again
//!   q Q                       quit
//!
//! A number before a move repeats it, and before g or G goes to that
//! line. The search is plain text, as grep's. The screen is the
//! console's size (trystd::io::terminal_size), asked before each screen,
//! or 24 by 80 when the console does not know it.
//!
//! The input is read whole into memory first, so `cmd | less` shows all
//! cmd said. Keys come from the console: standard input when it is the
//! console, else a descriptor of the console's own (console::open), as
//! Unix's less opens /dev/tty. The pager takes the console's foreground,
//! as vi does, so Ctrl-C is a key, which cancels a search being typed.
//! When standard output is not the console, less copies its input there
//! and ends, as Unix's does. Exit with 0, or with 1 if the file cannot be
//! read (said on standard error).
#![no_std]

use trystd::fs::File;
use trystd::prelude::*;
use trystd::{console, sys};

trystd::main!(run);

/// The screen when the console does not know its size.
const ROWS: usize = 24;
const COLS: usize = 80;
const TAB: usize = 8;

const ESC: u8 = 27;
const CTRL_B: u8 = 2;
const CTRL_C: u8 = sys::CTRL_C as u8;
const CTRL_D: u8 = 4;
const CTRL_E: u8 = 5;
const CTRL_F: u8 = 6;
const CTRL_H: u8 = 8;
const CTRL_L: u8 = 12;
const CTRL_N: u8 = 14;
const CTRL_P: u8 = 16;
const CTRL_U: u8 = 21;
const CTRL_V: u8 = 22;
const CTRL_Y: u8 = 25;
const DEL: u8 = 127;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Key {
    Char(u8),
    Enter,
    Backspace,
    Esc,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Other,
}

/// Where the keys come from: standard input, or the console's own
/// descriptor when standard input is the text.
enum Keys {
    Stdin,
    Console(File),
}

/// Keys, read a byte at a time so that what is typed after quitting is
/// left for the shell. An escape followed by `[` or `O` starts a key's
/// sequence (an arrow); on its own it is the Escape key.
struct Input {
    from: Keys,
    esc: bool,
    cr: bool,
}

impl Input {
    fn byte(&mut self) -> Option<u8> {
        let mut b = [0u8; 1];
        let n = match &mut self.from {
            Keys::Stdin => io::stdin().read(&mut b),
            Keys::Console(f) => f.read(&mut b),
        };
        match n {
            Ok(1) => Some(b[0]),
            _ => None,
        }
    }

    /// The next key; None at the end of input.
    fn key(&mut self) -> Option<Key> {
        loop {
            let b = self.byte()?;
            let (cr, esc) = (self.cr, self.esc);
            self.cr = b == b'\r';
            self.esc = b == ESC;
            return Some(match b {
                b'[' | b'O' if esc => match self.sequence()? {
                    Key::Other => continue,
                    k => k,
                },
                b'\r' => Key::Enter,
                b'\n' if cr => continue,
                b'\n' => Key::Enter,
                DEL | CTRL_H => Key::Backspace,
                ESC => Key::Esc,
                _ => Key::Char(b),
            });
        }
    }

    /// The rest of ESC [ ... or ESC O ...: parameters, then a final byte.
    fn sequence(&mut self) -> Option<Key> {
        let mut param = 0usize;
        loop {
            let b = self.byte()?;
            match b {
                b'0'..=b'9' => param = param * 10 + (b - b'0') as usize,
                b';' => param = 0,
                0x40..=0x7e => {
                    return Some(match (b, param) {
                        (b'A', _) => Key::Up,
                        (b'B', _) => Key::Down,
                        (b'H', _) | (b'~', 1) | (b'~', 7) => Key::Home,
                        (b'F', _) | (b'~', 4) | (b'~', 8) => Key::End,
                        (b'~', 5) => Key::PageUp,
                        (b'~', 6) => Key::PageDown,
                        _ => Key::Other,
                    });
                }
                _ => return Some(Key::Other),
            }
        }
    }
}

/// A place on the screen's first row: a line, and which of the rows it
/// wraps into.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Pos {
    line: usize,
    row: usize,
}

struct Pager<'a> {
    text: Vec<u8>,
    /// Where each line starts and ends in text, its newline left out.
    lines: Vec<(usize, usize)>,
    name: Option<&'a str>,
    top: Pos,
    rows: usize,
    cols: usize,
    /// What / or ? looks for, and whether the last search went back.
    pattern: Vec<u8>,
    back: bool,
    /// The search being typed after / or ?, and which.
    prompt: Option<(u8, Vec<u8>)>,
    count: Option<usize>,
    msg: &'static str,
    quit: bool,
    screen: Vec<u8>,
}

/// How many columns `b` takes at column `col`.
fn width(b: u8, col: usize) -> usize {
    match b {
        b'\t' => TAB - col % TAB,
        0..=31 | DEL => 2,
        _ => 1,
    }
}

impl Pager<'_> {
    fn line(&self, i: usize) -> &[u8] {
        let (start, end) = self.lines[i];
        &self.text[start..end]
    }

    /// How many screen rows line `i` wraps into.
    fn rows_of(&self, i: usize) -> usize {
        let mut col = 0;
        for &b in self.line(i) {
            col += width(b, col);
        }
        col.div_ceil(self.cols).max(1)
    }

    /// Rows for text: all but the last, which is the status line.
    fn text_rows(&self) -> usize {
        self.rows - 1
    }

    fn next(&self, p: Pos) -> Option<Pos> {
        if p.row + 1 < self.rows_of(p.line) {
            Some(Pos { line: p.line, row: p.row + 1 })
        } else if p.line + 1 < self.lines.len() {
            Some(Pos { line: p.line + 1, row: 0 })
        } else {
            None
        }
    }

    fn prev(&self, p: Pos) -> Option<Pos> {
        if p.row > 0 {
            Some(Pos { line: p.line, row: p.row - 1 })
        } else if p.line > 0 {
            Some(Pos { line: p.line - 1, row: self.rows_of(p.line - 1) - 1 })
        } else {
            None
        }
    }

    /// The furthest the first row goes: where the last screen starts.
    fn last_top(&self) -> Pos {
        let Some(last) = self.lines.len().checked_sub(1) else {
            return Pos { line: 0, row: 0 };
        };
        let mut p = Pos { line: last, row: self.rows_of(last) - 1 };
        for _ in 1..self.text_rows() {
            match self.prev(p) {
                Some(q) => p = q,
                None => break,
            }
        }
        p
    }

    fn down(&mut self, n: usize) {
        let end = self.last_top();
        for _ in 0..n {
            if self.top >= end {
                break;
            }
            match self.next(self.top) {
                Some(p) => self.top = p,
                None => break,
            }
        }
    }

    fn up(&mut self, n: usize) {
        for _ in 0..n {
            match self.prev(self.top) {
                Some(p) => self.top = p,
                None => break,
            }
        }
    }

    /// Put line `i` (from 0) on the first row, or as near as the end allows.
    fn go(&mut self, i: usize) {
        let i = i.min(self.lines.len().saturating_sub(1));
        self.top = Pos { line: i, row: 0 }.min(self.last_top());
    }

    /// Find the pattern from the line after the first row's (before it,
    /// going back), and show that line first.
    fn search(&mut self, back: bool) {
        if self.pattern.is_empty() {
            self.msg = "No previous search";
            return;
        }
        let n = self.lines.len();
        let found = if back {
            (0..self.top.line).rev().find(|&i| self.holds(i))
        } else {
            (self.top.line + 1..n).find(|&i| self.holds(i))
        };
        match found {
            Some(i) => self.go(i),
            None => self.msg = "Pattern not found",
        }
    }

    fn holds(&self, i: usize) -> bool {
        let p = &self.pattern[..];
        self.line(i).windows(p.len()).any(|w| w == p)
    }

    fn key(&mut self, key: Key) {
        if let Some((kind, typed)) = &mut self.prompt {
            match key {
                Key::Char(CTRL_C) | Key::Esc => self.prompt = None,
                Key::Backspace if typed.is_empty() => self.prompt = None,
                Key::Backspace => {
                    typed.pop();
                }
                Key::Enter => {
                    let back = *kind == b'?';
                    if !typed.is_empty() {
                        self.pattern = core::mem::take(typed);
                    }
                    self.prompt = None;
                    self.back = back;
                    self.search(back);
                }
                Key::Char(c) if c >= b' ' => typed.push(c),
                _ => {}
            }
            return;
        }
        if let Key::Char(c @ b'0'..=b'9') = key {
            let n = self.count.unwrap_or(0);
            if n < 100_000_000 {
                self.count = Some(n * 10 + (c - b'0') as usize);
            }
            return;
        }
        let count = self.count.take();
        let screen = self.text_rows();
        let half = screen.div_ceil(2);
        match key {
            Key::Char(b'q' | b'Q') => self.quit = true,
            Key::Char(b' ' | b'f' | CTRL_F | CTRL_V) | Key::PageDown => self.down(count.unwrap_or(screen)),
            Key::Char(b'b' | CTRL_B) | Key::PageUp => self.up(count.unwrap_or(screen)),
            Key::Char(b'j' | b'e' | CTRL_N | CTRL_E) | Key::Enter | Key::Down => self.down(count.unwrap_or(1)),
            Key::Char(b'k' | b'y' | CTRL_P | CTRL_Y) | Key::Up => self.up(count.unwrap_or(1)),
            Key::Char(b'd' | CTRL_D) => self.down(count.unwrap_or(half)),
            Key::Char(b'u' | CTRL_U) => self.up(count.unwrap_or(half)),
            Key::Char(b'g' | b'<') | Key::Home => self.go(count.unwrap_or(1).saturating_sub(1)),
            Key::Char(b'G' | b'>') | Key::End => match count {
                Some(n) => self.go(n.saturating_sub(1)),
                None => self.top = self.last_top(),
            },
            Key::Char(c @ (b'/' | b'?')) => self.prompt = Some((c, Vec::new())),
            Key::Char(b'n') => self.search(self.back),
            Key::Char(b'N') => self.search(!self.back),
            _ => {} // r and Ctrl-L too: every key draws the screen again
        }
    }

    fn out(&mut self, b: &[u8]) {
        self.screen.extend_from_slice(b);
    }

    /// Row `row` of line `i`, matches of the pattern in reverse video.
    fn row(&mut self, i: usize, row: usize) {
        let (start, end) = self.lines[i];
        let (first, last) = (row * self.cols, (row + 1) * self.cols);
        let p = self.pattern.len();
        let mut col = 0;
        let mut lit = 0; // bytes of a match still to show in reverse
        let mut reverse = false;
        for k in start..end {
            let b = self.text[k];
            if p > 0 && lit == 0 && end - k >= p && self.text[k..k + p] == self.pattern[..] {
                lit = p;
            }
            let on = lit > 0;
            lit = lit.saturating_sub(1);
            let w = width(b, col);
            for c in 0..w {
                let at = col + c;
                if at < first || at >= last {
                    continue;
                }
                if on != reverse {
                    reverse = on;
                    self.out(if on { b"\x1b[7m" } else { b"\x1b[27m" });
                }
                let shown = match b {
                    b'\t' => b' ',
                    0..=31 | DEL if c == 0 => b'^',
                    0..=31 => b + b'@',
                    DEL => b'?',
                    _ => b,
                };
                self.screen.push(shown);
            }
            col += w;
            if col >= last {
                break;
            }
        }
        if reverse {
            self.out(b"\x1b[27m");
        }
        if col < last {
            self.out(b"\x1b[K");
        }
    }

    /// Write the whole screen at once, at the size the console has now.
    fn draw(&mut self) {
        let (cols, rows) = io::terminal_size().unwrap_or((COLS, ROWS));
        let (cols, rows) = (cols.max(2), rows.max(2));
        if (cols, rows) != (self.cols, self.rows) {
            // Rows wrap differently now: keep the first row's line.
            (self.cols, self.rows) = (cols, rows);
            self.top = Pos { line: self.top.line, row: 0 }.min(self.last_top());
        }
        self.out(b"\x1b[?25l\x1b[H");
        let mut p = Some(self.top);
        for r in 0..self.text_rows() {
            if r > 0 {
                self.out(b"\r\n");
            }
            match p {
                Some(at) if !self.lines.is_empty() => {
                    self.row(at.line, at.row);
                    p = self.next(at);
                }
                _ => self.out(b"~\x1b[K"),
            }
        }
        self.out(b"\r\n\x1b[7m");
        let at_end = self.top >= self.last_top();
        match self.prompt.take() {
            Some((kind, typed)) => {
                self.out(b"\x1b[27m");
                self.screen.push(kind);
                let shown = typed.len().min(cols - 2);
                self.out(&typed[typed.len() - shown..]);
                self.prompt = Some((kind, typed));
            }
            None if !self.msg.is_empty() => {
                let msg = core::mem::take(&mut self.msg);
                self.out(&msg.as_bytes()[..msg.len().min(cols - 1)]);
            }
            None if at_end => self.out(b"(END)"),
            None => match self.name {
                Some(name) if self.top == (Pos { line: 0, row: 0 }) => {
                    self.out(&name.as_bytes()[..name.len().min(cols - 1)]);
                }
                _ => self.out(b":"),
            },
        }
        self.out(b"\x1b[27m\x1b[K\x1b[?25h");
        self.flush();
    }

    fn flush(&mut self) {
        let mut out = io::stdout();
        let _ = out.write_all(&self.screen).and_then(|()| out.flush());
        self.screen.clear();
    }
}

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let name = args.next();
    if args.next().is_some() || name.is_some_and(|n| n.starts_with('-') && n != "-") {
        Line::new().str("usage: less [FILE]").eprint();
        return 1;
    }
    let from_stdin = name.is_none_or(|n| n == "-");
    if from_stdin && io::is_terminal(sys::STDIN) {
        Line::new().str("less: missing filename").eprint();
        return 1;
    }
    let mut text = Vec::new();
    let read = if from_stdin {
        io::stdin().read_to_end(&mut text)
    } else {
        File::open(name.unwrap_or_default()).and_then(|mut f| f.read_to_end(&mut text))
    };
    if let Err(e) = read {
        Line::new().str("less: ").str(name.unwrap_or("-")).str(": ").error(&e).eprint();
        return 1;
    }
    if !io::is_terminal(sys::STDOUT) {
        let mut out = io::stdout();
        return out.write_all(&text).and_then(|()| out.flush()).is_err() as i32;
    }
    let from = if io::is_terminal(sys::STDIN) {
        Keys::Stdin
    } else {
        match console::open() {
            Ok(fd) => Keys::Console(File::from_fd(fd)),
            Err(e) => {
                Line::new().str("less: the console: ").error(&e).eprint();
                return 1;
            }
        }
    };

    let mut lines = Vec::new();
    let mut start = 0;
    for (i, &b) in text.iter().enumerate() {
        if b == b'\n' {
            // A CR before the newline is the line's end too.
            let end = if i > start && text[i - 1] == b'\r' { i - 1 } else { i };
            lines.push((start, end));
            start = i + 1;
        }
    }
    if start < text.len() {
        lines.push((start, text.len()));
    }
    let mut pager = Pager {
        text,
        lines,
        name: name.filter(|_| !from_stdin),
        top: Pos { line: 0, row: 0 },
        rows: ROWS,
        cols: COLS,
        pattern: Vec::new(),
        back: false,
        prompt: None,
        count: None,
        msg: "",
        quit: false,
        screen: Vec::new(),
    };
    // The keys are the pager's, Ctrl-C too.
    let _ = console::set_foreground(None);
    let mut input = Input { from, esc: false, cr: false };
    pager.out(b"\x1b[?1049h\x1b[2J");
    pager.draw();
    while !pager.quit {
        match input.key() {
            Some(key) => pager.key(key),
            None => break,
        }
        if !pager.quit {
            pager.draw();
        }
    }
    pager.out(b"\x1b[2J\x1b[H\x1b[?1049l");
    pager.flush();
    0
}
