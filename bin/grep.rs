//! grep [-v] TEXT [FILE]...: say each line of the files, or of standard
//! input when none is named, that holds TEXT, or with -v each line that
//! does not, on standard output, as Unix's grep does for a fixed string
//! (grep -F): there are no patterns. With two files or more, each line
//! starts with its file's name and a colon. A line longer than LINE
//! code points is taken a LINE at a time. Exit with 0 if a line was
//! said, 1 if none was, and 2 if a file cannot be opened (said on
//! standard error) or output fails. A filter too: ls bin | grep e.
#![no_std]

use trystd::fs::File;
use trystd::prelude::*;

trystd::main!(run);

/// The longest line looked at whole. A buffer on the stack, not a Vec:
/// a program that keeps off the heap needs a page less.
const LINE: usize = 729;

struct Grep<'a> {
    text: &'a [u8],
    invert: bool,
    found: bool,
}

impl Grep<'_> {
    fn holds(&self, line: &[u8]) -> bool {
        self.text.is_empty() || line.windows(self.text.len()).any(|w| w == self.text)
    }

    /// Say `line` if holding the text is what -v asks for, after `name`
    /// and a colon unless `name` is empty.
    fn look(&mut self, line: &[u8], name: &str) -> io::Result<()> {
        if self.holds(line) == self.invert {
            return Ok(());
        }
        self.found = true;
        let mut out = io::stdout();
        if !name.is_empty() {
            out.write_all(name.as_bytes())?;
            out.write_all(b":")?;
        }
        out.write_all(line)?;
        out.write_all(b"\n")
    }

    /// Look at each line `from` reads, to its end.
    fn file<R: Read>(&mut self, from: &mut R, name: &str) -> io::Result<()> {
        let mut line = [0u8; LINE];
        let mut n = 0;
        let mut buf = [0u8; 243];
        loop {
            let got = from.read(&mut buf)?;
            if got == 0 {
                break;
            }
            for &b in &buf[..got] {
                if b != b'\n' {
                    line[n] = b;
                    n += 1;
                    if n < LINE {
                        continue;
                    }
                }
                self.look(&line[..n], name)?; // a line, or as much as fits
                n = 0;
            }
        }
        if n > 0 {
            self.look(&line[..n], name)?; // a last line with no newline
        }
        io::stdout().flush()
    }
}

fn usage() -> i32 {
    Line::new().str("usage: grep [-v] TEXT [FILE]...").eprint();
    2
}

fn run() -> i32 {
    let mut args = env::args().skip(1).peekable();
    let mut invert = false;
    if args.peek().is_some_and(|a| a.starts_with('-')) {
        if args.next() != Some("-v") {
            return usage();
        }
        invert = true;
    }
    let Some(text) = args.next() else {
        return usage();
    };
    let mut grep = Grep { text: text.as_bytes(), invert, found: false };
    let mut failed = false;
    let named = args.len() > 1;
    if args.len() == 0 {
        failed = grep.file(&mut io::stdin(), "").is_err();
    }
    for name in args {
        let done = File::open(name).and_then(|mut f| grep.file(&mut f, if named { name } else { "" }));
        if let Err(e) = done {
            Line::new().str("grep: ").str(name).str(": ").error(&e).eprint();
            failed = true;
        }
    }
    if failed {
        2
    } else if grep.found {
        0
    } else {
        1
    }
}
