//! The line editor. Keys edit the line at the cursor, as in a Unix
//! shell's: left and right (or Ctrl-B, Ctrl-F), Home and End (Ctrl-A,
//! Ctrl-E), Backspace, Delete (Ctrl-D is the live console's end of
//! input), Ctrl-U and Ctrl-K (erase before and after the cursor), Ctrl-W
//! (the word before it), Ctrl-L (clear the screen), up and down (Ctrl-P,
//! Ctrl-N) through the last `HIST_N` lines typed, Ctrl-C (drop the line)
//! and Tab, which completes a command or a path.
//!
//! The terminal follows with what any terminal understands: a backspace
//! moves left and a character prints over what is there, so the line's
//! tail is printed again after a change. What a key prints is gathered
//! and written before the next key is read.

use trystd::fs::{self, File};
use trystd::prelude::*;
use trystd::sys;

use crate::LINE_MAX;
use crate::builtin::BUILTINS;
use crate::out::{Out, fd_file};

/// Lines up and down go through.
const HIST_N: usize = 16;
/// Columns Tab's list fills when the console does not know its width.
const COLS: usize = 80;
const NAME: usize = sys::NAME_MAX as usize;

const BS: u8 = 8;
const BEL: u8 = 7;
const ESC: u8 = 27;
const DEL: u8 = 127;
const CR: u8 = 13;
const CTRL_A: u8 = 1;
const CTRL_B: u8 = 2;
const CTRL_C: u8 = sys::CTRL_C as u8;
const CTRL_E: u8 = 5;
const CTRL_F: u8 = 6;
const CTRL_K: u8 = 11;
const CTRL_L: u8 = 12;
const CTRL_N: u8 = 14;
const CTRL_P: u8 = 16;
const CTRL_U: u8 = 21;
const CTRL_W: u8 = 23;

/// What came before a key.
#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Plain,
    /// A carriage return: a newline right after it ends nothing more.
    Cr,
    Esc,
    /// Inside ESC [ or ESC O, before its final character.
    Seq,
}

/// What `read` ended with.
pub enum Got {
    Line,
    /// Ctrl-C: the line is dropped.
    Cancel,
    /// The end of standard input.
    End,
}

pub struct Editor {
    line: [u8; LINE_MAX],
    len: usize,
    cur: usize,
    hist: [[u8; LINE_MAX]; HIST_N],
    hlen: [u8; HIST_N],
    nhist: usize,
    /// The history line shown: `nhist` is the line being typed, which
    /// waits in `draft` meanwhile.
    hpos: usize,
    draft: [u8; LINE_MAX],
    dlen: usize,
    state: State,
    /// An escape sequence's number, as the 3 of ESC [ 3 ~.
    param: i32,
    /// The last key was a Tab that found several names.
    tabbed: bool,
    out: Out,
    tab: Tab,
}

/// Tab's work: the names it finds for the word before the cursor.
struct Tab {
    /// The word names a command, not a path.
    cmd: bool,
    /// Where the name being completed starts in the line, past the
    /// word's last slash, and how much of it is typed.
    at: usize,
    typed: usize,
    /// The directory, as typed, slash and all.
    dir: [u8; LINE_MAX],
    dlen: usize,
    /// Names found, what they share, the longest one's length.
    found: usize,
    shared: [u8; NAME + 1],
    slen: usize,
    widest: usize,
    /// Printing them in columns: the column's width, columns to a row,
    /// the one it is at and the spaces still owed before it.
    listing: bool,
    width: usize,
    cols: usize,
    col: usize,
    pad: usize,
}

impl Editor {
    pub const fn new() -> Editor {
        Editor {
            line: [0; LINE_MAX],
            len: 0,
            cur: 0,
            hist: [[0; LINE_MAX]; HIST_N],
            hlen: [0; HIST_N],
            nhist: 0,
            hpos: 0,
            draft: [0; LINE_MAX],
            dlen: 0,
            state: State::Plain,
            param: 0,
            tabbed: false,
            out: Out::new(1),
            tab: Tab {
                cmd: false,
                at: 0,
                typed: 0,
                dir: [0; LINE_MAX],
                dlen: 0,
                found: 0,
                shared: [0; NAME + 1],
                slen: 0,
                widest: 0,
                listing: false,
                width: 0,
                cols: 0,
                col: 0,
                pad: 0,
            },
        }
    }

    /// The line as typed, once `read` gives `Got::Line`.
    pub fn line(&self) -> &[u8] {
        &self.line[..self.len]
    }

    /// Read a line from standard input, the prompt printed already.
    pub fn read(&mut self) -> Got {
        self.len = 0;
        self.cur = 0;
        self.hpos = self.nhist;
        loop {
            self.out.flush();
            let mut ch = [0u8; 1];
            match fd_file(sys::STDIN).read(&mut ch) {
                Ok(1) => {}
                _ => {
                    self.out.nl(); // end the prompt's line
                    return Got::End;
                }
            }
            let c = ch[0];
            if c == 0 {
                continue; // NUL is ignored
            }
            let tabbed = core::mem::replace(&mut self.tabbed, false);
            let state = core::mem::replace(&mut self.state, State::Plain);
            match state {
                State::Esc => {
                    // ESC [ and ESC O start a sequence, as the arrow keys
                    // send; anything else after ESC (Alt+key) is dropped.
                    if c == b'[' || c == b'O' {
                        self.param = 0;
                        self.state = State::Seq;
                    }
                    continue;
                }
                State::Seq => {
                    // The final character, @ to ~, says the key; a number
                    // may come before it, and of several the last counts.
                    if c >= b'@' {
                        self.sequence(c);
                    } else {
                        self.state = State::Seq;
                        if c.is_ascii_digit() {
                            self.param = self.param * 10 + (c - b'0') as i32;
                        } else {
                            self.param = 0;
                        }
                    }
                    continue;
                }
                _ => {}
            }
            match c {
                ESC => self.state = State::Esc,
                CR | b'\n' => {
                    // Enter may send CR, LF or CR LF: one line each.
                    if c == CR {
                        self.state = State::Cr;
                    } else if state == State::Cr {
                        continue;
                    }
                    self.show(self.cur);
                    self.out.nl();
                    self.remember();
                    return Got::Line;
                }
                CTRL_C => {
                    self.out.b(b"^C\n").flush();
                    return Got::Cancel;
                }
                BS | DEL => self.backspace(),
                b'\t' => self.complete(tabbed),
                CTRL_A => self.home(),
                CTRL_E => self.end(),
                CTRL_B => self.left(),
                CTRL_F => self.right(),
                CTRL_U => self.del_back(self.cur),
                CTRL_K => self.del_fwd(self.len - self.cur),
                CTRL_W => {
                    let mut t = self.cur;
                    while t > 0 && self.line[t - 1] == b' ' {
                        t -= 1;
                    }
                    while t > 0 && self.line[t - 1] != b' ' {
                        t -= 1;
                    }
                    self.del_back(self.cur - t);
                }
                CTRL_L => {
                    self.out.b(b"\x1b[H\x1b[2J");
                    self.redraw();
                }
                CTRL_P => self.up(),
                CTRL_N => self.down(),
                _ if c < b' ' => {} // other control characters are dropped
                _ => {
                    if self.len < LINE_MAX {
                        self.insert(c);
                    }
                }
            }
        }
    }

    /// The escape sequence ending in `c`.
    fn sequence(&mut self, c: u8) {
        match (c, self.param) {
            (b'A', _) => self.up(),
            (b'B', _) => self.down(),
            (b'C', _) => self.right(),
            (b'D', _) => self.left(),
            (b'H', _) | (b'~', 1 | 7) => self.home(),
            (b'F', _) | (b'~', 4 | 8) => self.end(),
            (b'~', 3) => {
                if self.cur < self.len {
                    self.del_fwd(1);
                }
            }
            _ => {}
        }
    }

    // --- moving and changing ----------------------------------------------------

    fn left(&mut self) {
        if self.cur > 0 {
            self.cur -= 1;
            self.out.c(BS);
        }
    }

    fn right(&mut self) {
        if self.cur < self.len {
            // Printing it moves past it.
            self.out.c(self.line[self.cur]);
            self.cur += 1;
        }
    }

    fn home(&mut self) {
        self.out.rep(self.cur as isize, BS);
        self.cur = 0;
    }

    fn end(&mut self) {
        self.show(self.cur);
        self.cur = self.len;
    }

    fn backspace(&mut self) {
        if self.cur > 0 {
            self.del_back(1);
        }
    }

    /// Put `c` in at the cursor, which moves past it; the caller sees
    /// that there is room.
    fn insert(&mut self, c: u8) {
        self.line.copy_within(self.cur..self.len, self.cur + 1);
        self.line[self.cur] = c;
        self.len += 1;
        self.show(self.cur);
        self.cur += 1;
        self.out.rep((self.len - self.cur) as isize, BS);
    }

    /// Erase the `n` characters before the cursor.
    fn del_back(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        self.out.rep(n as isize, BS);
        self.cur -= n;
        self.del_fwd(n);
    }

    /// Erase the `n` characters from the cursor on: what follows closes
    /// up, is printed again, and blanks what it left behind.
    fn del_fwd(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        self.line.copy_within(self.cur + n..self.len, self.cur);
        self.len -= n;
        self.show(self.cur);
        self.out.rep(n as isize, b' ');
        self.out.rep((n + self.len - self.cur) as isize, BS);
    }

    /// Print the line from `from` to its end.
    fn show(&mut self, from: usize) {
        let (line, len) = (self.line, self.len);
        self.out.b(&line[from..len]);
    }

    /// The prompt and the line again, the cursor back where it was.
    fn redraw(&mut self) {
        self.out.b(crate::PROMPT);
        self.show(0);
        self.out.rep((self.len - self.cur) as isize, BS);
    }

    /// Make the line `text`, shown in place of the old one, with the
    /// cursor at its end.
    fn set_line(&mut self, text: &[u8]) {
        let old = self.len;
        self.out.rep(self.cur as isize, BS);
        self.line[..text.len()].copy_from_slice(text);
        self.len = text.len();
        self.show(0);
        self.cur = self.len;
        let blank = old as isize - self.len as isize;
        self.out.rep(blank, b' ').rep(blank, BS);
    }

    // --- history ----------------------------------------------------------------

    fn up(&mut self) {
        if self.hpos == 0 {
            return;
        }
        if self.hpos == self.nhist {
            self.draft = self.line;
            self.dlen = self.len;
        }
        self.hpos -= 1;
        let k = self.hpos;
        let h = self.hist[k];
        self.set_line(&h[..self.hlen[k] as usize]);
    }

    fn down(&mut self) {
        if self.hpos >= self.nhist {
            return;
        }
        self.hpos += 1;
        let k = self.hpos;
        if k == self.nhist {
            let d = self.draft;
            self.set_line(&d[..self.dlen]);
        } else {
            let h = self.hist[k];
            self.set_line(&h[..self.hlen[k] as usize]);
        }
    }

    /// Keep the line as the newest in the history, unless it is empty or
    /// the newest already; the oldest goes when `HIST_N` are kept.
    fn remember(&mut self) {
        let n = self.nhist;
        if self.len == 0 || (n > 0 && self.hist[n - 1][..self.hlen[n - 1] as usize] == *self.line())
        {
            return;
        }
        let k = if n == HIST_N {
            self.hist.copy_within(1.., 0);
            self.hlen.copy_within(1.., 0);
            n - 1
        } else {
            self.nhist += 1;
            n
        };
        self.hist[k] = self.line;
        self.hlen[k] = self.len as u8;
    }

    // --- Tab ----------------------------------------------------------------------

    /// Complete the word before the cursor. The first word of a command
    /// (at the start or after |) names a built-in, a program of the
    /// image or one in /bin; any other word, or one with a slash, a path,
    /// whose directory is read for the names that start with what follows
    /// its last slash. One name: the rest of it is typed, then a space, or
    /// a slash after a directory. Several: as much as they share; when
    /// that adds nothing, a bell, and a second Tab lists them in columns
    /// across the console's width and prints the line again. Names
    /// starting with a dot are left out unless the word starts so too.
    fn complete(&mut self, again: bool) {
        let mut start = self.cur;
        while start > 0 && !matches!(self.line[start - 1], b' ' | b'|' | b'<' | b'>') {
            start -= 1;
        }
        let mut t = start;
        while t > 0 && self.line[t - 1] == b' ' {
            t -= 1;
        }
        let tab = &mut self.tab;
        tab.cmd = t == 0 || self.line[t - 1] == b'|';
        tab.at = start;
        for k in start..self.cur {
            if self.line[k] == b'/' {
                tab.at = k + 1;
                tab.cmd = false; // a path, even first
            }
        }
        tab.typed = self.cur - tab.at;
        tab.dlen = tab.at - start;
        tab.dir[..tab.dlen].copy_from_slice(&self.line[start..tab.at]);
        tab.found = 0;
        tab.slen = 0;
        tab.widest = 0;
        tab.listing = false;
        self.names();
        if self.tab.found == 0 {
            self.out.c(BEL);
            return;
        }
        for k in self.tab.typed..self.tab.slen {
            if self.len == LINE_MAX {
                return; // the line is full
            }
            self.insert(self.tab.shared[k]);
        }
        if self.tab.found == 1 {
            let shared = self.tab.shared;
            let after = if !self.tab.cmd && self.is_dir(&shared[..self.tab.slen]) {
                b'/'
            } else {
                b' '
            };
            if self.len < LINE_MAX {
                self.insert(after);
            }
            return;
        }
        if self.tab.slen > self.tab.typed {
            return; // it went further: that will do
        }
        self.tabbed = true;
        if !again {
            self.out.c(BEL);
            return;
        }
        self.out.c(b'\n');
        let tab = &mut self.tab;
        tab.listing = true;
        tab.col = 0;
        tab.pad = 0;
        // A column: the longest name, room for a directory's slash, and
        // two spaces; as many as the console is wide.
        tab.width = tab.widest + 2 + if tab.cmd { 0 } else { 1 };
        let wide = io::terminal_size().map_or(COLS, |(c, _)| c);
        tab.cols = (wide / tab.width).max(1);
        self.names();
        if self.tab.col != 0 {
            self.out.c(b'\n');
        }
        self.redraw();
    }

    /// Call `name` with each name Tab may complete to: the built-ins,
    /// the image's programs and /bin's files for a command, else the
    /// names in the word's directory.
    fn names(&mut self) {
        let mut path = [0u8; LINE_MAX];
        let dir: &[u8] = if self.tab.cmd {
            for &(b, _) in BUILTINS {
                self.name(b);
            }
            for &(p, _) in crate::run::PROGRAMS {
                self.name(p);
            }
            b"/bin"
        } else {
            // As typed, but for its last slash, or . if nothing was.
            let n = self.tab.dlen;
            path[..n].copy_from_slice(&self.tab.dir[..n]);
            match n {
                0 => b".",
                1 => &path[..1],
                _ => &path[..n - 1],
            }
        };
        let Ok(dir) = File::open(dir) else {
            return; // nothing there: no names
        };
        let dot = self.tab.typed > 0 && self.line[self.tab.at] == b'.';
        let mut buf = [0u8; NAME + 1];
        while let Ok(Some(name)) = dir.read_name(&mut buf) {
            if name == b"." || name == b".." || (name.first() == Some(&b'.') && !dot) {
                continue;
            }
            let mut copy = [0u8; NAME + 1];
            copy[..name.len()].copy_from_slice(name);
            let n = name.len();
            self.name(&copy[..n]);
        }
    }

    /// If `name` starts with what is typed: count it and keep what all
    /// such share, or while listing, print it in its column.
    fn name(&mut self, name: &[u8]) {
        let (at, typed) = (self.tab.at, self.tab.typed);
        if !name.starts_with(&self.line[at..at + typed]) {
            return;
        }
        let mut len = name.len();
        if self.tab.listing {
            self.out.rep(self.tab.pad as isize, b' ').b(name);
            if !self.tab.cmd && self.is_dir(name) {
                self.out.c(b'/');
                len += 1;
            }
            let tab = &mut self.tab;
            tab.pad = tab.width.saturating_sub(len);
            tab.col += 1;
            if tab.col >= tab.cols {
                self.out.c(b'\n'); // the row is full
                self.tab.col = 0;
                self.tab.pad = 0;
            }
            return;
        }
        let tab = &mut self.tab;
        tab.widest = tab.widest.max(len);
        tab.found += 1;
        if tab.found == 1 {
            tab.shared[..len].copy_from_slice(name);
            tab.slen = len;
        } else {
            len = len.min(tab.slen);
            tab.slen = (0..len).find(|&k| tab.shared[k] != name[k]).unwrap_or(len);
        }
    }

    /// Whether `name`, in the word's directory, is a directory.
    fn is_dir(&self, name: &[u8]) -> bool {
        let mut path = [0u8; LINE_MAX + NAME + 1];
        let n = self.tab.dlen;
        path[..n].copy_from_slice(&self.tab.dir[..n]);
        path[n..n + name.len()].copy_from_slice(name);
        fs::metadata(&path[..n + name.len()]).is_ok_and(|m| m.is_dir())
    }
}
