//! vi [FILE]: a screen editor in the manner of Unix's vi, small. The
//! file is read whole into memory as lines and written back whole with
//! `:w`; a FILE that does not exist yet is made by the first write.
//!
//! Normal mode moves:
//!
//!   h j k l, arrows   left, down, up, right     0 ^ $   line start, text, end
//!   w b e             words                     gg G    first, last line
//!   f t F T + char    to (or till) a character on the line; ; again, , back
//!   %                 to the matching bracket   + - Enter  next, previous line
//!   / ? + text        search forward, back      n N     again, the other way
//!   Ctrl-F Ctrl-B     a screen down, up         Ctrl-D Ctrl-U  half a screen
//!
//! A search is plain text, except that a leading `^` ties it to a line's
//! start and a trailing `$` to its end; it goes round the end of the file.
//!
//! The operators d (delete), c (change: delete, then insert) and y (copy)
//! take a move after them, or themselves for whole lines: `dw`, `c$`,
//! `y2j`, `d/word`, `dd`, `cc`, `yy`. `cw` changes to the word's end.
//! Other changes:
//!
//!   x X               delete under, before      D C     delete, change to end
//!   s S               change a character, line  Y       copy the line
//!   p P               put after, before         J       join with the next line
//!   r                 replace a character       ~       swap case
//!   i a I A o O       insert before, after, at line start, end, below, above
//!   .                 repeat the last change
//!   u Ctrl-R          undo, redo (the last 50 changes)
//!   ZZ ZQ             write if changed and quit; quit
//!   :                 a command: w [FILE], q, q!, wq, x, NUMBER, $
//!
//! A count before a move or change repeats it (`3dd`, `5j`, `d2w`). Insert
//! mode takes text, Enter and Backspace (which joins lines at a line's
//! start) and arrows; Escape goes back to normal mode. An insert is one
//! change to undo, and `.` repeats it with the text typed.
//!
//! The terminal is driven with ANSI sequences: the alternate screen
//! while the editor runs, and each row written in place. The screen is
//! the console's size (trystd::io::terminal_size), asked again before
//! each screen so that a resized window is filled, or 24 by 80 when the
//! console does not know it. The console already
//! gives each key as it is typed, without echo; the editor also takes
//! the console's foreground away (CN_FOREGROUND, NO_FOREGROUND), so a
//! Ctrl-C reaches it as a key, which cancels, instead of killing it with
//! the file unsaved. Exit with 0, or with 1 when the input ended with
//! changes not written, or for a file that cannot be read.
//!
//! Screens are built by hand into one buffer and written at once, with
//! no core::fmt: a String::push is some 150 steps on this machine, and a
//! formatted number some 1,000.
#![no_std]

use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

/// The screen when the console does not know its size.
const ROWS: usize = 24;
const COLS: usize = 80;
/// The widest screen drawn; a wider terminal shows this much.
const MAX_COLS: usize = 729;
const TAB: usize = 8;

const ESC: u8 = 27;
const CTRL_B: u8 = 2;
const CTRL_C: u8 = sys::CTRL_C as u8;
const CTRL_D: u8 = 4;
const CTRL_F: u8 = 6;
const CTRL_G: u8 = 7;
const CTRL_H: u8 = 8;
const CTRL_L: u8 = 12;
const CTRL_N: u8 = 14;
const CTRL_P: u8 = 16;
const CTRL_R: u8 = 18;
const CTRL_U: u8 = 21;
const DEL: u8 = 127;

static CONSOLE: sys::Server = sys::Server::new(b"console\0", sys::CONSOLE_PROTOCOL);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Key {
    Char(u8),
    Enter,
    Backspace,
    Esc,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    Delete,
    PageUp,
    PageDown,
}

/// Keys from standard input, read a byte at a time, so that what is
/// typed after the editor quits is left for the shell. There is no
/// asking whether more input waits, so an escape is the Escape key at
/// once; when `[` or `O` follows it, the three or more bytes were a key's
/// sequence (an arrow), and the key comes with `after_esc` set, for the
/// editor to take back what the Escape did.
struct Input {
    /// The last byte was an escape, or a CR, whose LF is the same Enter.
    esc: bool,
    cr: bool,
}

impl Input {
    fn new() -> Input {
        Input { esc: false, cr: false }
    }

    /// The next byte; None at the end of input.
    fn byte(&mut self) -> Option<u8> {
        let mut b = [0u8; 1];
        match io::stdin().read(&mut b) {
            Ok(1) => Some(b[0]),
            _ => None,
        }
    }

    /// The next key, and whether it is a sequence an Escape started.
    fn key(&mut self) -> Option<(Key, bool)> {
        loop {
            let b = self.byte()?;
            let (cr, esc) = (self.cr, self.esc);
            self.cr = b == b'\r';
            self.esc = b == ESC;
            let key = match b {
                b'[' | b'O' if esc => match self.sequence()? {
                    Some(k) => return Some((k, true)),
                    None => continue,
                },
                b'\r' => Key::Enter,
                b'\n' if cr => continue,
                b'\n' => Key::Enter,
                DEL | CTRL_H => Key::Backspace,
                ESC => Key::Esc,
                _ => Key::Char(b),
            };
            return Some((key, false));
        }
    }

    /// The rest of ESC [ ... or ESC O ...: its parameters, then its final
    /// character. Some(None) for a sequence the editor does not know.
    fn sequence(&mut self) -> Option<Option<Key>> {
        let mut param = 0usize;
        loop {
            let b = self.byte()?;
            match b {
                b'0'..=b'9' => param = param * 10 + (b - b'0') as usize,
                b';' => param = 0,
                0x40..=0x7e => {
                    return Some(match (b, param) {
                        (b'A', _) => Some(Key::Up),
                        (b'B', _) => Some(Key::Down),
                        (b'C', _) => Some(Key::Right),
                        (b'D', _) => Some(Key::Left),
                        (b'H', _) | (b'~', 1) | (b'~', 7) => Some(Key::Home),
                        (b'F', _) | (b'~', 4) | (b'~', 8) => Some(Key::End),
                        (b'~', 3) => Some(Key::Delete),
                        (b'~', 5) => Some(Key::PageUp),
                        (b'~', 6) => Some(Key::PageDown),
                        _ => None,
                    });
                }
                _ => return Some(None),
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Normal,
    Insert,
    /// Typing a `:` command or a `/` or `?` search into `Editor::cmd`,
    /// after `Editor::prompt`.
    Command,
}

/// What a motion did, for an operator: the range it covers runs to the
/// character before the cursor (exclusive), takes the cursor's character
/// too (inclusive), or is whole lines.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// Not a motion.
    No,
    /// A motion that could not move (no match): an operator does nothing.
    Fail,
    Exclusive,
    Inclusive,
    Lines,
}

/// A copy of the text and cursor, for `u` and Ctrl-R.
struct Snapshot {
    lines: Vec<Vec<u8>>,
    cy: usize,
    cx: usize,
    changed: bool,
}

/// The changes `u` can take back, oldest dropped first: each is a copy
/// of the whole text.
const UNDO_MAX: usize = 50;

struct Editor {
    /// Never empty: an empty file is one empty line.
    lines: Vec<Vec<u8>>,
    /// The cursor: a line, and a byte in it.
    cy: usize,
    cx: usize,
    /// The column vertical moves aim for; usize::MAX after `$`.
    want: usize,
    /// The first line and column on the screen.
    top: usize,
    left: usize,
    mode: Mode,
    name: Option<String>,
    changed: bool,
    msg: Vec<u8>,
    cmd: Vec<u8>,
    /// The command line's first character: `:`, `/` or `?`.
    prompt: u8,
    /// Text the operators and `x` took, for `p` and `P`: whole lines, or
    /// (when `whole` is false) a piece of text, a line break between
    /// each two parts.
    yank: Vec<Vec<u8>>,
    whole: bool,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    /// The normal-mode command being typed: count, operator, count,
    /// motion, the motion's character.
    keys: Vec<u8>,
    /// The keys since the command began, and those of the last change,
    /// for `.`.
    rec: Vec<Key>,
    dot: Vec<Key>,
    /// The last search, and whether it went backwards (`?`).
    pattern: Vec<u8>,
    back: bool,
    /// The last f, t, F or T and its character, for `;` and `,`.
    find: (u8, u8),
    /// An operator's motion is moving: the cursor may go past the
    /// line's last character.
    oping: bool,
    quit: bool,
    /// What the last Escape changed: the mode and column before it.
    escaped: Option<(Mode, usize)>,
    screen: Vec<u8>,
    /// The screen's size, from the console before each draw.
    rows: usize,
    cols: usize,
}

fn run() -> i32 {
    let args: Vec<&str> = env::args().skip(1).collect();
    let mut ed = Editor::new();
    match args.as_slice() {
        [] => {}
        [name] => {
            if let Err(code) = ed.load(name) {
                return code;
            }
        }
        _ => {
            eprintln!("usage: vi [FILE]");
            return 2;
        }
    }
    // The keys are the editor's, Ctrl-C too. Without a console server
    // (input from a pipe) there is no foreground to give back.
    let _ = CONSOLE.call(sys::CN_FOREGROUND, &[sys::NO_FOREGROUND]);
    let mut input = Input::new();
    ed.out(b"\x1b[?1049h");
    ed.draw();
    let mut code = 0;
    while !ed.quit {
        match input.key() {
            Some((key, after_esc)) => {
                if after_esc {
                    ed.unescape();
                }
                ed.key(key)
            }
            None => {
                if ed.changed {
                    code = 1;
                }
                break;
            }
        }
        ed.draw();
    }
    ed.screen.clear();
    ed.out(b"\x1b[2J\x1b[H\x1b[?1049l");
    ed.flush();
    if code != 0 {
        eprintln!("vi: input ended, changes not written");
    }
    code
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// What sort of character for `w`, `b` and `e`: 0 blank, 1 word, 2 other.
fn class(b: u8) -> u8 {
    if b == b' ' || b == b'\t' {
        0
    } else if is_word(b) {
        1
    } else {
        2
    }
}

/// `n` in decimal onto `to`, without core::fmt.
fn decimal(to: &mut Vec<u8>, n: usize) {
    let mut digits = [0u8; 10];
    let mut k = digits.len();
    let mut m = n as u32;
    loop {
        k -= 1;
        digits[k] = b'0' + (m % 10) as u8;
        m /= 10;
        if m == 0 {
            break;
        }
    }
    to.extend_from_slice(&digits[k..]);
}

fn number(s: &[u8]) -> Option<usize> {
    if s.is_empty() || s.len() > 9 {
        return None;
    }
    let mut n = 0usize;
    for &b in s {
        if !b.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (b - b'0') as usize;
    }
    Some(n)
}

impl Editor {
    fn new() -> Editor {
        Editor {
            lines: vec![Vec::new()],
            cy: 0,
            cx: 0,
            want: 0,
            top: 0,
            left: 0,
            mode: Mode::Normal,
            name: None,
            changed: false,
            msg: Vec::new(),
            cmd: Vec::new(),
            prompt: b':',
            yank: Vec::new(),
            whole: false,
            undo: Vec::new(),
            redo: Vec::new(),
            keys: Vec::new(),
            rec: Vec::new(),
            dot: Vec::new(),
            pattern: Vec::new(),
            back: false,
            find: (0, 0),
            oping: false,
            quit: false,
            escaped: None,
            screen: Vec::with_capacity(ROWS * (COLS + 12)),
            rows: ROWS,
            cols: COLS,
        }
    }

    // --- files -----------------------------------------------------------

    /// Read `name` in, or start it empty when it does not exist. Err with
    /// the exit code when it cannot be read.
    fn load(&mut self, name: &str) -> Result<(), i32> {
        self.name = Some(String::from(name));
        match fs::read(name) {
            Ok(bytes) => {
                self.lines = bytes.split(|&b| b == b'\n').map(|l| l.to_vec()).collect();
                if self.lines.len() > 1 && bytes.last() == Some(&b'\n') {
                    self.lines.pop();
                }
                self.msg.clear();
                self.quoted_name();
                self.msg.push(b' ');
                self.counts(bytes.len());
                Ok(())
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                self.msg.clear();
                self.quoted_name();
                self.msg.extend_from_slice(b" [New]");
                Ok(())
            }
            Err(e) => {
                eprintln!("vi: {name}: {e}");
                Err(1)
            }
        }
    }

    fn quoted_name(&mut self) {
        self.msg.push(b'"');
        match &self.name {
            Some(n) => self.msg.extend_from_slice(n.as_bytes()),
            None => self.msg.extend_from_slice(b"[No Name]"),
        }
        self.msg.push(b'"');
    }

    /// "NL, NB" onto the message: the lines, and `bytes`.
    fn counts(&mut self, bytes: usize) {
        decimal(&mut self.msg, self.lines.len());
        self.msg.extend_from_slice(b"L, ");
        decimal(&mut self.msg, bytes);
        self.msg.push(b'B');
    }

    /// Write the text to `to`, or to the file's own name. True if written.
    fn write(&mut self, to: Option<&[u8]>) -> bool {
        if let Some(to) = to {
            if self.name.is_none() {
                self.name = Some(String::from(core::str::from_utf8(to).unwrap_or("")));
            }
        }
        let name: Vec<u8> = match (to, &self.name) {
            (Some(to), _) => to.to_vec(),
            (None, Some(n)) => n.as_bytes().to_vec(),
            (None, None) => {
                self.say(b"No file name");
                return false;
            }
        };
        let mut bytes = Vec::new();
        if !(self.lines.len() == 1 && self.lines[0].is_empty()) {
            for line in &self.lines {
                bytes.extend_from_slice(line);
                bytes.push(b'\n');
            }
        }
        match fs::write(&name[..], &bytes) {
            Ok(()) => {
                if to.is_none() || self.name.as_ref().map(|n| n.as_bytes()) == to {
                    // Every text undo goes back to differs from the file now.
                    self.changed = false;
                    self.undo.iter_mut().chain(self.redo.iter_mut()).for_each(|s| s.changed = true);
                }
                self.msg.clear();
                self.msg.push(b'"');
                self.msg.extend_from_slice(&name);
                self.msg.extend_from_slice(b"\" ");
                self.counts(bytes.len());
                self.msg.extend_from_slice(b" written");
                true
            }
            Err(e) => {
                self.msg.clear();
                self.msg.extend_from_slice(&name);
                self.msg.extend_from_slice(b": ");
                let mut s = String::new();
                let _ = core::fmt::write(&mut s, format_args!("{e}"));
                self.msg.extend_from_slice(s.as_bytes());
                false
            }
        }
    }

    fn say(&mut self, s: &[u8]) {
        self.msg.clear();
        self.msg.extend_from_slice(s);
    }

    // --- the cursor --------------------------------------------------------

    fn line(&self) -> &Vec<u8> {
        &self.lines[self.cy]
    }

    /// The last column the cursor may be on: past the end in insert mode.
    fn max_x(&self) -> usize {
        let n = self.line().len();
        if self.mode == Mode::Insert || self.oping || n == 0 { n } else { n - 1 }
    }

    fn clamp_x(&mut self) {
        self.cx = self.cx.min(self.max_x());
    }

    /// To line `y`, at the column vertical moves aim for.
    fn to_line(&mut self, y: usize) {
        self.cy = y.min(self.lines.len() - 1);
        self.cx = self.want;
        self.clamp_x();
    }

    fn set_x(&mut self, x: usize) {
        self.cx = x;
        self.clamp_x();
        self.want = self.cx;
    }

    fn first_text(&self) -> usize {
        self.line().iter().position(|&b| b != b' ' && b != b'\t').unwrap_or(0)
    }

    /// The character at (y, x), or a blank past a line's end, so that a
    /// line break counts as a gap between words.
    fn at(&self, y: usize, x: usize) -> u8 {
        *self.lines[y].get(x).unwrap_or(&b' ')
    }

    /// The position after (y, x), across lines; None at the text's end.
    fn next(&self, y: usize, x: usize) -> Option<(usize, usize)> {
        if x < self.lines[y].len() {
            Some((y, x + 1))
        } else if y + 1 < self.lines.len() {
            Some((y + 1, 0))
        } else {
            None
        }
    }

    fn prev(&self, y: usize, x: usize) -> Option<(usize, usize)> {
        if x > 0 {
            Some((y, x - 1))
        } else if y > 0 {
            Some((y - 1, self.lines[y - 1].len()))
        } else {
            None
        }
    }

    /// `w`: to the next word's start. An empty line is a word.
    fn word_forward(&mut self) {
        let (mut y, mut x) = (self.cy, self.cx);
        let c = class(self.at(y, x));
        while let Some((ny, nx)) = self.next(y, x) {
            if ny != y {
                (y, x) = (ny, nx);
                break;
            }
            (y, x) = (ny, nx);
            if class(self.at(y, x)) != c {
                break;
            }
        }
        while class(self.at(y, x)) == 0 && !self.lines[y].is_empty() {
            match self.next(y, x) {
                Some((ny, nx)) => (y, x) = (ny, nx),
                None => break,
            }
        }
        self.cy = y;
        self.set_x(x);
    }

    /// `b`: to the start of this word, or the one before.
    fn word_back(&mut self) {
        let (mut y, mut x) = (self.cy, self.cx);
        loop {
            match self.prev(y, x) {
                Some((ny, nx)) => (y, x) = (ny, nx),
                None => break,
            }
            if class(self.at(y, x)) != 0 || self.lines[y].is_empty() {
                break;
            }
        }
        let c = class(self.at(y, x));
        while x > 0 && c != 0 && class(self.at(y, x - 1)) == c {
            x -= 1;
        }
        self.cy = y;
        self.set_x(x);
    }

    /// `e`: to the end of this word, or the next.
    fn word_end(&mut self) {
        let (mut y, mut x) = (self.cy, self.cx);
        loop {
            match self.next(y, x) {
                Some((ny, nx)) => (y, x) = (ny, nx),
                None => break,
            }
            if class(self.at(y, x)) != 0 {
                break;
            }
        }
        let c = class(self.at(y, x));
        while c != 0 && x + 1 < self.lines[y].len() && class(self.at(y, x + 1)) == c {
            x += 1;
        }
        self.cy = y;
        self.set_x(x);
    }

    /// f, t (forward) or F, T (backward) to the `n`th `c` on the line.
    /// `again` for `;` and `,`: a t or T does not stop where it stands.
    fn find_char(&mut self, kind: u8, c: u8, n: usize, again: bool) -> bool {
        let till = kind == b't' || kind == b'T';
        let line = &self.lines[self.cy];
        let mut p = self.cx;
        if kind == b'f' || kind == b't' {
            p += (till && again) as usize;
            for _ in 0..n {
                match line.iter().skip(p + 1).position(|&b| b == c) {
                    Some(k) => p += k + 1,
                    None => return false,
                }
            }
            self.set_x(p - till as usize);
        } else {
            p = p.saturating_sub((till && again) as usize);
            for _ in 0..n {
                match line[..p.min(line.len())].iter().rposition(|&b| b == c) {
                    Some(k) => p = k,
                    None => return false,
                }
            }
            self.set_x(p + till as usize);
        }
        true
    }

    /// `%`: from the first bracket at or after the cursor on the line to
    /// the one that matches it.
    fn bracket(&mut self) -> bool {
        const PAIRS: &[u8] = b"()[]{}";
        let Some(off) = self.line().iter().skip(self.cx).position(|b| PAIRS.contains(b)) else {
            return false;
        };
        let (mut y, mut x) = (self.cy, self.cx + off);
        let k = PAIRS.iter().position(|&b| b == self.at(y, x)).unwrap_or(0);
        let (open, close) = (PAIRS[k & !1], PAIRS[k | 1]);
        let mut depth = 0isize;
        loop {
            let b = self.at(y, x);
            depth += (b == open) as isize - (b == close) as isize;
            if depth == 0 {
                break;
            }
            let step = if k & 1 == 0 { self.next(y, x) } else { self.prev(y, x) };
            match step {
                Some(p) => (y, x) = p,
                None => return false,
            }
        }
        self.cy = y;
        self.set_x(x);
        true
    }

    /// Where `self.pattern` matches line `y`: the first place at or after
    /// `from` (forward) or the last before `to`, both bytes. A pattern
    /// that starts with `^` matches only at a line's start, one that ends
    /// with `$` only at its end; the rest is plain text.
    fn match_in(&self, y: usize, from: usize, to: usize, back: bool) -> Option<usize> {
        let mut pat = &self.pattern[..];
        let start = pat.first() == Some(&b'^');
        if start {
            pat = &pat[1..];
        }
        let end = pat.last() == Some(&b'$');
        if end {
            pat = &pat[..pat.len() - 1];
        }
        let line = &self.lines[y];
        if pat.len() > line.len() {
            return None;
        }
        let ok = |&p: &usize| {
            p >= from
                && p < to
                && line[p..p + pat.len()] == *pat
                && (!start || p == 0)
                && (!end || p + pat.len() == line.len())
        };
        let mut all = 0..=line.len() - pat.len();
        if back { all.rfind(ok) } else { all.find(ok) }
    }

    /// `n`: to the next match of the last search, in its direction or
    /// (`back`) the other way, round the end of the text.
    fn search(&mut self, back: bool) -> bool {
        if self.pattern.is_empty() {
            self.say(b"No previous regular expression");
            return false;
        }
        let n = self.lines.len();
        let (cy, cx) = (self.cy, self.cx);
        for k in 0..=n {
            let y = if back { (cy + n - k % n) % n } else { (cy + k) % n };
            let (from, to) = match (k, back) {
                (0, false) => (cx + 1, usize::MAX),
                (0, true) => (0, cx),
                (_, false) if k == n => (0, cx + 1),
                (_, true) if k == n => (cx, usize::MAX),
                _ => (0, usize::MAX),
            };
            if let Some(x) = self.match_in(y, from, to, back) {
                if (!back && y < cy) || (!back && y == cy && k > 0) {
                    self.say(b"search hit BOTTOM, continuing at TOP");
                } else if (back && y > cy) || (back && y == cy && k > 0) {
                    self.say(b"search hit TOP, continuing at BOTTOM");
                }
                self.cy = y;
                self.set_x(x);
                return true;
            }
        }
        self.say(b"Pattern not found: ");
        self.msg.extend_from_slice(&self.pattern.clone());
        false
    }

    /// Move as motion `m` (with its character `arg`) does, `n` times;
    /// `given` is the count as typed, 0 for none. What sort of motion it
    /// was, or Kind::No when `m` is not one.
    fn motion(&mut self, m: u8, arg: u8, n: usize, given: usize) -> Kind {
        let text = self.text();
        let page = text.saturating_sub(2).max(1);
        let ok = |moved: bool| if moved { Kind::Exclusive } else { Kind::Fail };
        match m {
            b'h' | CTRL_H => self.set_x(self.cx.saturating_sub(n)),
            b'l' | b' ' => self.set_x(self.cx + n),
            b'0' => self.set_x(0),
            b'^' => self.set_x(self.first_text()),
            b'w' => (0..n).for_each(|_| self.word_forward()),
            b'b' => (0..n).for_each(|_| self.word_back()),
            b'n' => return ok(self.search(self.back)),
            b'N' => return ok(self.search(!self.back)),
            b'e' => {
                (0..n).for_each(|_| self.word_end());
                return Kind::Inclusive;
            }
            b'$' => {
                self.cy = (self.cy + n - 1).min(self.lines.len() - 1);
                self.set_x(usize::MAX);
                self.want = usize::MAX;
                return Kind::Inclusive;
            }
            b'%' => return if self.bracket() { Kind::Inclusive } else { Kind::Fail },
            b'f' | b't' | b'F' | b'T' | b';' | b',' => {
                let again = m == b';' || m == b',';
                if !again {
                    self.find = (m, arg);
                }
                let (mut kind, c) = self.find;
                if m == b',' {
                    kind ^= b'f' ^ b'F'; // the same letter, the other case
                }
                if c == 0 || !self.find_char(kind, c, n, again) {
                    return Kind::Fail;
                }
                return if kind == b'f' || kind == b't' {
                    Kind::Inclusive
                } else {
                    Kind::Exclusive
                };
            }
            _ => {
                match m {
                    b'j' | CTRL_N => self.to_line(self.cy + n),
                    b'k' | CTRL_P => self.to_line(self.cy.saturating_sub(n)),
                    b'+' | b'\r' => {
                        self.to_line(self.cy + n);
                        self.set_x(self.first_text());
                    }
                    b'-' => {
                        self.to_line(self.cy.saturating_sub(n));
                        self.set_x(self.first_text());
                    }
                    b'G' | b'g' => {
                        if m == b'g' && arg != b'g' {
                            return Kind::No;
                        }
                        let last = if m == b'G' { self.lines.len() } else { 1 };
                        self.to_line((if given > 0 { given } else { last }) - 1);
                        self.set_x(self.first_text());
                    }
                    CTRL_F => {
                        self.top = (self.top + page * n).min(self.lines.len() - 1);
                        self.to_line(self.top.max(self.cy));
                    }
                    CTRL_B => {
                        self.top = self.top.saturating_sub(page * n);
                        self.to_line(self.cy.min(self.top + text - 1));
                    }
                    CTRL_D => self.to_line(self.cy + text / 2),
                    CTRL_U => self.to_line(self.cy.saturating_sub(text / 2)),
                    _ => return Kind::No,
                }
                return Kind::Lines;
            }
        }
        Kind::Exclusive
    }

    // --- changes -----------------------------------------------------------

    /// Keep the text as it is for `u`, before a change.
    fn save(&mut self) {
        if self.undo.len() == UNDO_MAX {
            self.undo.remove(0);
        }
        let snap = self.snapshot();
        self.undo.push(snap);
        self.redo.clear();
        self.changed = true;
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot { lines: self.lines.clone(), cy: self.cy, cx: self.cx, changed: self.changed }
    }

    /// `u` (`redo` false) or Ctrl-R: back to the text one list holds, the
    /// text as it is now going on the other.
    fn undo(&mut self, redo: bool) {
        let (from, to) =
            if redo { (&mut self.redo, &mut self.undo) } else { (&mut self.undo, &mut self.redo) };
        let Some(snap) = from.pop() else {
            return self.say(if redo {
                b"Already at newest change"
            } else {
                b"Already at oldest change"
            });
        };
        to.push(Snapshot {
            lines: core::mem::replace(&mut self.lines, snap.lines),
            cy: self.cy,
            cx: self.cx,
            changed: self.changed,
        });
        self.changed = snap.changed;
        self.cy = snap.cy.min(self.lines.len() - 1);
        self.set_x(snap.cx);
    }

    /// Operator `op` (d, c or y) over what motion `m` moves across, or over
    /// `n` whole lines when `m` is the operator again (dd, cc, yy).
    fn operate(&mut self, op: u8, mut m: u8, arg: u8, n: usize, given: usize) {
        let (sy, sx) = (self.cy, self.cx);
        let kind = if m == op {
            self.cy = (sy + n - 1).min(self.lines.len() - 1);
            Kind::Lines
        } else {
            // cw changes the word, not the blanks after it, as ce does.
            if op == b'c' && m == b'w' && class(self.at(sy, sx)) != 0 {
                m = b'e';
            }
            self.oping = true;
            let kind = self.motion(m, arg, n, given);
            self.oping = false;
            kind
        };
        let to = (self.cy, self.cx);
        self.cy = sy;
        self.cx = sx;
        match kind {
            Kind::No => self.say(b"Unknown command"),
            Kind::Fail => {}
            _ => self.apply(op, kind, (sy, sx), to),
        }
        self.clamp_x();
    }

    fn apply(&mut self, op: u8, kind: Kind, a: (usize, usize), b: (usize, usize)) {
        let (a, mut b) = if b < a { (b, a) } else { (a, b) };
        if kind == Kind::Lines {
            self.yank = self.lines[a.0..=b.0].to_vec();
            self.whole = true;
            self.cy = a.0;
            if op == b'y' {
                return;
            }
            self.save();
            self.lines.drain(a.0..=b.0);
            if op == b'c' || self.lines.is_empty() {
                self.lines.insert(a.0, Vec::new());
            }
            self.cy = a.0.min(self.lines.len() - 1);
            self.cx = 0;
            if op == b'c' {
                return self.insert_mode();
            }
            return self.set_x(self.first_text());
        }
        // An exclusive motion that ends at a line's start stops at the end
        // of the line before: dw on a line's last word keeps the break.
        if kind == Kind::Exclusive && b.1 == 0 && b.0 > a.0 {
            b = (b.0 - 1, usize::MAX);
        }
        if kind == Kind::Inclusive {
            b.1 = b.1.saturating_add(1);
        }
        b.1 = b.1.min(self.lines[b.0].len());
        let mut text = Vec::new();
        for y in a.0..=b.0 {
            let from = if y == a.0 { a.1 } else { 0 };
            let to = if y == b.0 { b.1 } else { self.lines[y].len() };
            text.push(self.lines[y][from.min(to)..to].to_vec());
        }
        if a != b {
            self.yank = text;
            self.whole = false;
        }
        self.cy = a.0;
        if op != b'y' && a != b {
            self.save();
            let tail = self.lines[b.0].split_off(b.1);
            self.lines.drain(a.0 + 1..=b.0);
            self.lines[a.0].truncate(a.1);
            self.lines[a.0].extend_from_slice(&tail);
        }
        if op == b'c' {
            if a == b {
                self.save();
            }
            self.insert_mode();
            self.cx = a.1;
            self.want = a.1;
        } else {
            self.set_x(a.1);
        }
    }

    fn put(&mut self, below: bool) {
        if self.yank.is_empty() {
            return;
        }
        if self.whole {
            let at = if below { self.cy + 1 } else { self.cy };
            for (k, line) in self.yank.iter().enumerate() {
                self.lines.insert(at + k, line.clone());
            }
            self.cy = at;
            return self.set_x(self.first_text());
        }
        let cy = self.cy;
        let line = &mut self.lines[cy];
        let at = (self.cx + (below && !line.is_empty()) as usize).min(line.len());
        let tail = line.split_off(at);
        line.extend_from_slice(&self.yank[0]);
        for (k, part) in self.yank[1..].iter().enumerate() {
            self.lines.insert(cy + 1 + k, part.clone());
        }
        let last = cy + self.yank.len() - 1;
        let end = self.lines[last].len();
        self.lines[last].extend_from_slice(&tail);
        self.set_x(if last == cy { end.saturating_sub(1) } else { at });
    }

    fn join(&mut self) {
        if self.cy + 1 >= self.lines.len() {
            return;
        }
        let next = self.lines.remove(self.cy + 1);
        let start = next.iter().position(|&b| b != b' ' && b != b'\t').unwrap_or(next.len());
        let line = &mut self.lines[self.cy];
        while line.last() == Some(&b' ') {
            line.pop();
        }
        let at = line.len();
        if !line.is_empty() && start < next.len() {
            line.push(b' ');
        }
        line.extend_from_slice(&next[start..]);
        self.set_x(at);
    }

    fn insert_mode(&mut self) {
        self.mode = Mode::Insert;
        self.say(b"-- INSERT --");
    }

    fn open_line(&mut self, below: bool) {
        self.save();
        let at = if below { self.cy + 1 } else { self.cy };
        self.lines.insert(at, Vec::new());
        self.cy = at;
        self.cx = 0;
        self.insert_mode();
    }

    // --- keys --------------------------------------------------------------

    fn key(&mut self, key: Key) {
        let mode = self.mode;
        let cx = self.cx;
        self.escaped = None;
        if key == Key::Esc {
            self.escaped = Some((mode, cx));
        }
        if mode == Mode::Normal && self.keys.is_empty() {
            self.rec.clear();
        }
        self.rec.push(key);
        match self.mode {
            Mode::Normal => self.normal(key),
            Mode::Insert => self.insert(key),
            Mode::Command => self.command_key(key),
        }
    }

    /// An Escape turned out to start an arrow's sequence: back to the mode
    /// it left, insert mode staying where it was. A `:` command it
    /// cancelled stays cancelled.
    fn unescape(&mut self) {
        if let Some((Mode::Insert, cx)) = self.escaped.take() {
            self.mode = Mode::Insert;
            self.cx = cx;
            self.want = cx;
            self.say(b"-- INSERT --");
        }
    }

    /// A key in normal mode: onto the command being typed, which runs once
    /// it is whole. Keys that are not characters stand for the command
    /// they move as.
    fn normal(&mut self, key: Key) {
        let b = match key {
            Key::Char(CTRL_C) | Key::Esc => return self.keys.clear(),
            Key::Char(b) => b,
            Key::Enter => b'\r',
            Key::Backspace => CTRL_H,
            Key::Left => b'h',
            Key::Right => b'l',
            Key::Up => b'k',
            Key::Down => b'j',
            Key::Home => b'0',
            Key::End => b'$',
            Key::Delete => b'x',
            Key::PageUp => CTRL_B,
            Key::PageDown => CTRL_F,
        };
        self.keys.push(b);
        self.run_keys();
    }

    /// Run the command in `self.keys` if it is whole: [count] [operator
    /// [count]] command [character]. A search's motion waits for its
    /// pattern on the command line.
    fn run_keys(&mut self) {
        let keys = self.keys.clone();
        let mut i = 0;
        let count = |i: &mut usize| {
            let mut n = 0usize;
            while *i < keys.len() && keys[*i].is_ascii_digit() && (keys[*i] != b'0' || n > 0) {
                n = (n * 10 + (keys[*i] - b'0') as usize).min(99_999);
                *i += 1;
            }
            n
        };
        let n1 = count(&mut i);
        let mut op = 0;
        let mut n2 = 0;
        if i < keys.len() && b"dcy".contains(&keys[i]) {
            op = keys[i];
            i += 1;
            n2 = count(&mut i);
        }
        let Some(&m) = keys.get(i) else { return };
        let arg = if b"fFtTrgZ".contains(&m) {
            match keys.get(i + 1) {
                Some(&a) => a,
                None => return,
            }
        } else {
            0
        };
        if m == b'/' || m == b'?' {
            self.mode = Mode::Command;
            self.prompt = m;
            self.cmd.clear();
            return;
        }
        self.keys.clear();
        self.msg.clear();
        let given = if n1 == 0 && n2 == 0 { 0 } else { n1.max(1) * n2.max(1) };
        let change = (op != 0 && op != b'y') || b"xXDCsSrJpP~iaIAoO".contains(&m);
        self.command(op, m, arg, given);
        if change && self.mode == Mode::Normal {
            self.dot = self.rec.clone();
        }
    }

    /// A whole normal-mode command.
    fn command(&mut self, op: u8, m: u8, arg: u8, given: usize) {
        let n = given.max(1);
        if op != 0 {
            return self.operate(op, m, arg, n, given);
        }
        // Commands that are an operator and a motion.
        let alias = match m {
            b'x' => b"dl",
            b'X' => b"dh",
            b'D' => b"d$",
            b'C' => b"c$",
            b's' => b"cl",
            b'S' => b"cc",
            b'Y' => b"yy",
            _ => b"  ",
        };
        if alias[0] != b' ' {
            return self.operate(alias[0], alias[1], 0, n, given);
        }
        match self.motion(m, arg, n, given) {
            Kind::No => {}
            _ => return,
        }
        match m {
            b'r' if arg >= b' ' && arg != DEL && !self.line().is_empty() => {
                self.save();
                let end = (self.cx + n).min(self.line().len());
                let cx = self.cx;
                self.lines[self.cy][cx..end].fill(arg);
                self.set_x(end - 1);
            }
            b'~' if !self.line().is_empty() => {
                self.save();
                let end = (self.cx + n).min(self.line().len());
                let cx = self.cx;
                for b in &mut self.lines[self.cy][cx..end] {
                    *b ^= if b.is_ascii_alphabetic() { 0x20 } else { 0 };
                }
                self.set_x(end);
            }
            b'J' => {
                self.save();
                (0..n.max(2) - 1).for_each(|_| self.join());
            }
            b'p' | b'P' if !self.yank.is_empty() => {
                self.save();
                (0..n).for_each(|_| self.put(m == b'p'));
            }
            b'u' => (0..n).for_each(|_| self.undo(false)),
            CTRL_R => (0..n).for_each(|_| self.undo(true)),
            b'.' => {
                let dot = self.dot.clone();
                for _ in 0..n {
                    dot.iter().for_each(|&k| self.key(k));
                }
            }
            b'i' | b'a' | b'I' | b'A' => {
                self.save();
                self.insert_mode();
                self.cx = match m {
                    b'a' if !self.line().is_empty() => self.cx + 1,
                    b'I' => self.first_text(),
                    b'A' => self.line().len(),
                    _ => self.cx,
                };
            }
            b'o' => self.open_line(true),
            b'O' => self.open_line(false),
            b':' => {
                self.mode = Mode::Command;
                self.prompt = b':';
                self.cmd.clear();
            }
            b'Z' if arg == b'Z' => self.ex(b"x"),
            b'Z' if arg == b'Q' => self.ex(b"q!"),
            CTRL_G => {
                self.quoted_name();
                if self.changed {
                    self.msg.extend_from_slice(b" [Modified]");
                }
                self.msg.extend_from_slice(b" line ");
                decimal(&mut self.msg, self.cy + 1);
                self.msg.extend_from_slice(b" of ");
                decimal(&mut self.msg, self.lines.len());
            }
            CTRL_L => self.out(b"\x1b[2J"),
            b'r' | b'~' | b'p' | b'P' => {}
            _ => self.say(b"Unknown command"),
        }
    }

    fn insert(&mut self, key: Key) {
        match key {
            Key::Esc | Key::Char(CTRL_C) => {
                self.mode = Mode::Normal;
                self.msg.clear();
                self.set_x(self.cx.saturating_sub(1));
                // An insert that typed nothing is no change to undo.
                if self.undo.last().is_some_and(|s| s.lines == self.lines) {
                    self.changed = self.undo.pop().is_some_and(|s| s.changed);
                }
                self.dot = self.rec.clone();
            }
            Key::Char(b) if b >= b' ' || b == b'\t' => {
                let cx = self.cx;
                self.lines[self.cy].insert(cx, b);
                self.cx += 1;
            }
            Key::Enter => {
                let cx = self.cx;
                let rest = self.lines[self.cy].split_off(cx);
                self.lines.insert(self.cy + 1, rest);
                self.cy += 1;
                self.cx = 0;
            }
            Key::Backspace => {
                if self.cx > 0 {
                    self.cx -= 1;
                    let cx = self.cx;
                    self.lines[self.cy].remove(cx);
                } else if self.cy > 0 {
                    let line = self.lines.remove(self.cy);
                    self.cy -= 1;
                    self.cx = self.line().len();
                    self.lines[self.cy].extend_from_slice(&line);
                }
            }
            Key::Delete => {
                let cx = self.cx;
                if cx < self.line().len() {
                    self.lines[self.cy].remove(cx);
                }
            }
            Key::Left => self.cx = self.cx.saturating_sub(1),
            Key::Right => self.cx = (self.cx + 1).min(self.line().len()),
            Key::Up => self.to_line(self.cy.saturating_sub(1)),
            Key::Down => self.to_line(self.cy + 1),
            Key::Home => self.cx = 0,
            Key::End => self.cx = self.line().len(),
            _ => {}
        }
        if !matches!(key, Key::Up | Key::Down) {
            self.want = self.cx;
        }
    }

    fn command_key(&mut self, key: Key) {
        match key {
            Key::Esc | Key::Char(CTRL_C) => {
                self.mode = Mode::Normal;
                self.msg.clear();
                self.keys.clear();
            }
            Key::Backspace if self.cmd.is_empty() => {
                self.mode = Mode::Normal;
                self.keys.clear();
            }
            Key::Backspace => {
                self.cmd.pop();
            }
            Key::Enter => {
                self.mode = Mode::Normal;
                let cmd = core::mem::take(&mut self.cmd);
                if self.prompt == b':' {
                    self.msg.clear();
                    return self.ex(&cmd);
                }
                // A search: the motion it ends becomes n, the way it went.
                if !cmd.is_empty() {
                    self.pattern = cmd;
                }
                self.back = self.prompt == b'?';
                self.keys.pop();
                self.keys.push(b'n');
                self.run_keys();
            }
            Key::Char(b) if b >= b' ' => self.cmd.push(b),
            _ => {}
        }
    }

    /// Run a `:` command.
    fn ex(&mut self, cmd: &[u8]) {
        let cmd = cmd.trim_ascii();
        let (word, arg) = match cmd.iter().position(|&b| b == b' ') {
            Some(k) => (&cmd[..k], Some(cmd[k..].trim_ascii())),
            None => (cmd, None),
        };
        let arg = arg.filter(|a| !a.is_empty());
        match word {
            b"" => {}
            b"w" => {
                self.write(arg);
            }
            b"wq" => {
                if self.write(arg) {
                    self.quit = true;
                }
            }
            b"x" => {
                if !self.changed && arg.is_none() || self.write(arg) {
                    self.quit = true;
                }
            }
            b"q" if self.changed => {
                self.say(b"No write since last change (add ! to override)");
            }
            b"q" | b"q!" => self.quit = true,
            b"$" => {
                self.to_line(self.lines.len() - 1);
                self.set_x(self.first_text());
            }
            _ => match number(word) {
                Some(n) => {
                    self.to_line(n.max(1) - 1);
                    self.set_x(self.first_text());
                }
                None => {
                    self.say(b"Not an editor command: ");
                    self.msg.extend_from_slice(cmd);
                }
            },
        }
    }

    // --- the screen --------------------------------------------------------

    /// The screen column of byte `x` of line `y`, tabs expanded.
    fn column(&self, y: usize, x: usize) -> usize {
        let mut col = 0;
        for &b in self.lines[y].iter().take(x) {
            col = if b == b'\t' { (col / TAB + 1) * TAB } else { col + 1 };
        }
        col
    }

    fn out(&mut self, s: &[u8]) {
        self.screen.extend_from_slice(s);
    }

    fn flush(&mut self) {
        let mut stdout = io::stdout();
        let _ = stdout.write_all(&self.screen).and_then(|_| stdout.flush());
        self.screen.clear();
    }

    /// Cursor to row `r`, column `c`, both from 0.
    fn goto(&mut self, r: usize, c: usize) {
        self.out(b"\x1b[");
        decimal(&mut self.screen, r + 1);
        self.out(b";");
        decimal(&mut self.screen, c + 1);
        self.out(b"H");
    }

    /// Text rows: the last row is the status line.
    fn text(&self) -> usize {
        self.rows - 1
    }

    /// Scroll so the cursor shows, then write every row, at the size the
    /// console has now.
    fn draw(&mut self) {
        let (cols, rows) = trystd::io::terminal_size().unwrap_or((COLS, ROWS));
        let (cols, rows) = (cols.clamp(2, MAX_COLS), rows.max(2));
        let resized = (cols, rows) != (self.cols, self.rows);
        (self.cols, self.rows) = (cols, rows);
        let text = self.text();
        if self.cy < self.top {
            self.top = self.cy;
        } else if self.cy >= self.top + text {
            self.top = self.cy + 1 - text;
        }
        let col = self.column(self.cy, self.cx);
        if col < self.left {
            self.left = col;
        } else if col >= self.left + cols {
            self.left = col + 1 - cols;
        }
        self.out(b"\x1b[?25l");
        if resized {
            self.out(b"\x1b[2J");
        }
        self.out(b"\x1b[H");
        for r in 0..text {
            if r > 0 {
                self.out(b"\r\n");
            }
            let y = self.top + r;
            if y >= self.lines.len() {
                self.out(b"~\x1b[K");
                continue;
            }
            self.row(y);
        }
        self.out(b"\r\n");
        let mut status = core::mem::take(&mut self.msg);
        if self.mode == Mode::Command {
            status.clear();
            status.push(self.prompt);
            status.extend_from_slice(&self.cmd);
        }
        let shown = status.len().min(cols - 1);
        self.out(&status[..shown]);
        self.out(b"\x1b[K");
        if self.mode == Mode::Command {
            self.out(b"\x1b[?25h");
        } else {
            let r = self.cy - self.top;
            let c = col - self.left;
            self.goto(r, c);
            self.out(b"\x1b[?25h");
        }
        if self.mode != Mode::Command {
            self.msg = status;
        }
        self.flush();
    }

    /// Line `y`'s part on the screen, tabs expanded to spaces.
    fn row(&mut self, y: usize) {
        let left = self.left;
        let line = core::mem::take(&mut self.lines[y]);
        let mut col = 0;
        let cols = self.cols;
        let mut shown = [0u8; MAX_COLS];
        let mut n = 0;
        for &b in line.iter() {
            let width = if b == b'\t' { TAB - col % TAB } else { 1 };
            for _ in 0..width {
                if col >= left && n < cols {
                    shown[n] = if b == b'\t' || b < b' ' || b >= DEL { b' ' } else { b };
                    n += 1;
                }
                col += 1;
            }
            if n == cols {
                break;
            }
        }
        self.lines[y] = line;
        self.out(&shown[..n]);
        if n < cols {
            self.out(b"\x1b[K");
        }
    }
}
