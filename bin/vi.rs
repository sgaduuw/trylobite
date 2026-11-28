//! vi [FILE]: a screen editor in the manner of Unix's vi, small. The
//! file is read whole into memory as lines and written back whole with
//! `:w`; a FILE that does not exist yet is made by the first write.
//!
//! Normal mode moves and changes:
//!
//!   h j k l, arrows   left, down, up, right     0 ^ $   line start, text, end
//!   w b e             words                     gg G    first, last line
//!   Ctrl-F Ctrl-B     a screen down, up         Ctrl-D Ctrl-U  half a screen
//!   x X               delete under, before      dd D    delete line, to end
//!   yy p P            copy line, put after, before
//!   r C               replace one character     J       join with the next line
//!   i a I A o O       insert before, after, at line start, end, below, above
//!   u                 undo the last change (again: redo it)
//!   ZZ                write if changed, and quit
//!   :                 a command: w [FILE], q, q!, wq, x, NUMBER, $
//!
//! A count before a move or change repeats it (`3dd`, `5j`). Insert
//! mode takes text, Enter and Backspace (which joins lines at a line's
//! start) and arrows; Escape goes back to normal mode.
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
    /// Typing a `:` command into `Editor::cmd`.
    Command,
}

/// A copy of the text and cursor, for `u`.
struct Snapshot {
    lines: Vec<Vec<u8>>,
    cy: usize,
    cx: usize,
}

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
    /// Lines `dd` and `yy` took, for `p` and `P`.
    yank: Vec<Vec<u8>>,
    undo: Option<Snapshot>,
    /// A count being typed, 0 for none.
    count: usize,
    /// The first key of a two-key command (d, y, g, r, Z), or 0.
    pending: u8,
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
            yank: Vec::new(),
            undo: None,
            count: 0,
            pending: 0,
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
                    self.changed = false;
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
        if self.mode == Mode::Insert || n == 0 {
            n
        } else {
            n - 1
        }
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

    // --- changes -----------------------------------------------------------

    /// Keep the text as it is for `u`, before a change.
    fn save(&mut self) {
        self.undo = Some(Snapshot { lines: self.lines.clone(), cy: self.cy, cx: self.cx });
    }

    fn undo(&mut self) {
        match self.undo.take() {
            Some(snap) => {
                let now = Snapshot {
                    lines: core::mem::replace(&mut self.lines, snap.lines),
                    cy: self.cy,
                    cx: self.cx,
                };
                self.undo = Some(now);
                self.cy = snap.cy.min(self.lines.len() - 1);
                self.set_x(snap.cx);
                self.changed = true;
            }
            None => self.say(b"Already at oldest change"),
        }
    }

    fn delete_lines(&mut self, n: usize) {
        let end = (self.cy + n).min(self.lines.len());
        self.yank = self.lines.drain(self.cy..end).collect();
        if self.lines.is_empty() {
            self.lines.push(Vec::new());
        }
        self.cy = self.cy.min(self.lines.len() - 1);
        self.set_x(self.first_text());
        self.changed = true;
    }

    fn put(&mut self, below: bool) {
        if self.yank.is_empty() {
            return;
        }
        let at = if below { self.cy + 1 } else { self.cy };
        for (k, line) in self.yank.iter().enumerate() {
            self.lines.insert(at + k, line.clone());
        }
        self.cy = at;
        self.set_x(self.first_text());
        self.changed = true;
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
        self.changed = true;
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
        self.changed = true;
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

    fn normal(&mut self, key: Key) {
        let pending = core::mem::replace(&mut self.pending, 0);
        if pending != 0 {
            let n = core::mem::replace(&mut self.count, 0).max(1);
            return self.second(pending, key, n);
        }
        if let Key::Char(b) = key {
            if b.is_ascii_digit() && (b != b'0' || self.count > 0) {
                self.count = (self.count * 10 + (b - b'0') as usize).min(99_999);
                return;
            }
        }
        if !matches!(key, Key::Char(b'd' | b'y' | b'g' | b'r' | b'Z')) {
            self.msg.clear();
        }
        let given = core::mem::replace(&mut self.count, 0);
        let n = given.max(1);
        let text = self.text();
        let page = text.saturating_sub(2).max(1);
        match key {
            Key::Char(b'h') | Key::Left | Key::Backspace => self.set_x(self.cx.saturating_sub(n)),
            Key::Char(b'l') | Key::Char(b' ') | Key::Right => self.set_x(self.cx + n),
            Key::Char(b'j') | Key::Char(CTRL_N) | Key::Down => self.to_line(self.cy + n),
            Key::Char(b'k') | Key::Char(CTRL_P) | Key::Up => self.to_line(self.cy.saturating_sub(n)),
            Key::Char(b'+') | Key::Enter => {
                self.to_line(self.cy + n);
                self.set_x(self.first_text());
            }
            Key::Char(b'-') => {
                self.to_line(self.cy.saturating_sub(n));
                self.set_x(self.first_text());
            }
            Key::Char(b'0') | Key::Home => self.set_x(0),
            Key::Char(b'^') => self.set_x(self.first_text()),
            Key::Char(b'$') | Key::End => {
                self.cy = (self.cy + n - 1).min(self.lines.len() - 1);
                self.set_x(usize::MAX);
                self.want = usize::MAX;
            }
            Key::Char(b'w') => (0..n).for_each(|_| self.word_forward()),
            Key::Char(b'b') => (0..n).for_each(|_| self.word_back()),
            Key::Char(b'e') => (0..n).for_each(|_| self.word_end()),
            Key::Char(b'G') => {
                let y = if given > 0 { given - 1 } else { self.lines.len() - 1 };
                self.to_line(y);
                self.set_x(self.first_text());
            }
            Key::Char(CTRL_F) | Key::PageDown => {
                self.top = (self.top + page * n).min(self.lines.len() - 1);
                self.to_line(self.top.max(self.cy));
            }
            Key::Char(CTRL_B) | Key::PageUp => {
                self.top = self.top.saturating_sub(page * n);
                self.to_line(self.cy.min(self.top + text - 1));
            }
            Key::Char(CTRL_D) => self.to_line(self.cy + text / 2),
            Key::Char(CTRL_U) => self.to_line(self.cy.saturating_sub(text / 2)),
            Key::Char(b'x') | Key::Delete => {
                if !self.line().is_empty() {
                    self.save();
                    let end = (self.cx + n).min(self.line().len());
                    let cx = self.cx;
                    self.lines[self.cy].drain(cx..end);
                    self.clamp_x();
                    self.changed = true;
                }
            }
            Key::Char(b'X') => {
                if self.cx > 0 {
                    self.save();
                    let start = self.cx.saturating_sub(n);
                    let cx = self.cx;
                    self.lines[self.cy].drain(start..cx);
                    self.set_x(start);
                    self.changed = true;
                }
            }
            Key::Char(b'D') | Key::Char(b'C') => {
                self.save();
                let cx = self.cx;
                self.lines[self.cy].truncate(cx);
                self.changed = true;
                if key == Key::Char(b'C') {
                    self.insert_mode();
                } else {
                    self.set_x(cx);
                }
            }
            Key::Char(b'J') => {
                self.save();
                (0..n.max(2) - 1).for_each(|_| self.join());
            }
            Key::Char(b'p') | Key::Char(b'P') => {
                self.save();
                (0..n).for_each(|_| self.put(key == Key::Char(b'p')));
            }
            Key::Char(b'u') => self.undo(),
            Key::Char(b'i') | Key::Char(b'a') | Key::Char(b'I') | Key::Char(b'A') => {
                self.save();
                self.insert_mode();
                self.cx = match key {
                    Key::Char(b'a') if !self.line().is_empty() => self.cx + 1,
                    Key::Char(b'I') => self.first_text(),
                    Key::Char(b'A') => self.line().len(),
                    _ => self.cx,
                };
            }
            Key::Char(b'o') => self.open_line(true),
            Key::Char(b'O') => self.open_line(false),
            Key::Char(b':') => {
                self.mode = Mode::Command;
                self.cmd.clear();
            }
            Key::Char(b'd' | b'y' | b'g' | b'r' | b'Z') => {
                if let Key::Char(b) = key {
                    self.pending = b;
                    self.count = given;
                }
            }
            Key::Char(CTRL_G) => {
                self.msg.clear();
                self.quoted_name();
                if self.changed {
                    self.msg.extend_from_slice(b" [Modified]");
                }
                self.msg.extend_from_slice(b" line ");
                decimal(&mut self.msg, self.cy + 1);
                self.msg.extend_from_slice(b" of ");
                decimal(&mut self.msg, self.lines.len());
            }
            Key::Char(CTRL_L) => self.out(b"\x1b[2J"),
            Key::Esc | Key::Char(CTRL_C) => {}
            _ => self.say(b"Unknown command"),
        }
    }

    /// The second key of a two-key command: dd, yy, gg, rX, ZZ.
    fn second(&mut self, first: u8, key: Key, n: usize) {
        match (first, key) {
            (b'd', Key::Char(b'd')) => {
                self.save();
                self.delete_lines(n);
            }
            (b'y', Key::Char(b'y')) => {
                let end = (self.cy + n).min(self.lines.len());
                self.yank = self.lines[self.cy..end].to_vec();
            }
            (b'g', Key::Char(b'g')) => {
                self.to_line(n - 1);
                self.set_x(self.first_text());
            }
            (b'r', Key::Char(c)) if c >= b' ' && c != DEL && !self.line().is_empty() => {
                self.save();
                let end = (self.cx + n).min(self.line().len());
                let cx = self.cx;
                self.lines[self.cy][cx..end].fill(c);
                self.set_x(end - 1);
                self.changed = true;
            }
            (b'Z', Key::Char(b'Z')) => self.ex(b"x"),
            _ => {}
        }
    }

    fn insert(&mut self, key: Key) {
        match key {
            Key::Esc | Key::Char(CTRL_C) => {
                self.mode = Mode::Normal;
                self.msg.clear();
                self.set_x(self.cx.saturating_sub(1));
            }
            Key::Char(b) if b >= b' ' || b == b'\t' => {
                let cx = self.cx;
                self.lines[self.cy].insert(cx, b);
                self.cx += 1;
                self.changed = true;
            }
            Key::Enter => {
                let cx = self.cx;
                let rest = self.lines[self.cy].split_off(cx);
                self.lines.insert(self.cy + 1, rest);
                self.cy += 1;
                self.cx = 0;
                self.changed = true;
            }
            Key::Backspace => {
                if self.cx > 0 {
                    self.cx -= 1;
                    let cx = self.cx;
                    self.lines[self.cy].remove(cx);
                    self.changed = true;
                } else if self.cy > 0 {
                    let line = self.lines.remove(self.cy);
                    self.cy -= 1;
                    self.cx = self.line().len();
                    self.lines[self.cy].extend_from_slice(&line);
                    self.changed = true;
                }
            }
            Key::Delete => {
                let cx = self.cx;
                if cx < self.line().len() {
                    self.lines[self.cy].remove(cx);
                    self.changed = true;
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
            }
            Key::Backspace if self.cmd.is_empty() => self.mode = Mode::Normal,
            Key::Backspace => {
                self.cmd.pop();
            }
            Key::Enter => {
                self.mode = Mode::Normal;
                let cmd = core::mem::take(&mut self.cmd);
                self.msg.clear();
                self.ex(&cmd);
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
            status.push(b':');
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
