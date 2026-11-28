//! tar -c|-t|-x [-v] [-f ARCHIVE] [PATH]...: make an archive of files and
//! directories, list one, or take the files out of one, as Unix's tar
//! does. The letters may come together and without the dash (`tar cvf
//! a.tar notes bin`); ARCHIVE `-`, or none, is standard output or input.
//!
//!   -c   archive each PATH, and all a directory holds, into ARCHIVE
//!   -t   say the name of each member of ARCHIVE (with -v, its type and size)
//!   -x   make each member of ARCHIVE here, directories first as needed
//!        and files made or emptied; with PATHs, only those and what
//!        they hold
//!   -v   with -c and -x, say each name as it goes (on standard error
//!        when the archive is standard output)
//!
//! The archive is POSIX's ustar format, a 512-tryte header before each
//! member and its data in 512-tryte records, two empty records at the
//! end: each tryte where a byte would be, so an archive of text files
//! is a tar file any tar reads, once its trytes are written out as bytes.
//! Each member keeps its mode, owner, group and modification time;
//! taking it out restores the mode and the time (not the owner, as a
//! Unix tar run by an ordinary user does). A name longer than 100 is split into the
//! header's prefix. Members whose names climb out with `..` are not
//! taken out, and a leading `/` is dropped, as GNU tar does. Exit with 0,
//! or with 2 if anything failed (said on standard error).
#![no_std]

use trystd::fs::{self, File};
use trystd::prelude::*;
use trystd::sys;
use trystd::time::SystemTime;

trystd::main!(run);

const RECORD: usize = 512;
type Header = [u8; RECORD];

// Where a ustar header keeps each field, and its size.
const NAME: (usize, usize) = (0, 100);
const MODE: (usize, usize) = (100, 8);
const UID: (usize, usize) = (108, 8);
const GID: (usize, usize) = (116, 8);
const SIZE: (usize, usize) = (124, 12);
const MTIME: (usize, usize) = (136, 12);
const CHKSUM: (usize, usize) = (148, 8);
const TYPEFLAG: usize = 156;
const MAGIC: (usize, usize) = (257, 8); // "ustar\0" and version "00"
const PREFIX: (usize, usize) = (345, 155);

const REGULAR: u8 = b'0';
const DIRECTORY: u8 = b'5';

/// Where the archive is, and what tar was asked.
struct Tar<'a> {
    verbose: bool,
    /// Where -v says names: standard error when the archive is on
    /// standard output.
    to_stderr: bool,
    /// The archive's inode, when it is a file, so -c leaves it out.
    archive_ino: Option<i32>,
    /// -x: only these members, and what they hold.
    only: &'a [&'a str],
    failed: bool,
}

/// An archive to read or write: a file, or standard input or output.
enum Archive {
    File(File),
    Std,
}

impl Read for Archive {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Archive::File(f) => f.read(buf),
            Archive::Std => io::stdin().read(buf),
        }
    }
}

impl Write for Archive {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Archive::File(f) => f.write(buf),
            Archive::Std => io::stdout().write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Archive::File(f) => f.flush(),
            Archive::Std => io::stdout().flush(),
        }
    }
}

/// Fill `buf` from `from`; false at a clean end before any of it.
fn read_full<R: Read>(from: &mut R, buf: &mut [u8]) -> io::Result<bool> {
    let mut n = 0;
    while n < buf.len() {
        let got = from.read(&mut buf[n..])?;
        if got == 0 {
            if n == 0 {
                return Ok(false);
            }
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive ends inside a record"));
        }
        n += got;
    }
    Ok(true)
}

/// `n` in octal, `width - 1` digits and a 0 after, into the field.
fn octal(h: &mut Header, (at, width): (usize, usize), mut n: u64) {
    h[at + width - 1] = 0;
    for i in (0..width - 1).rev() {
        h[at + i] = b'0' + (n & 7) as u8;
        n >>= 3;
    }
}

/// The octal number in a field, up to a space or 0.
fn read_octal(h: &Header, (at, width): (usize, usize)) -> Option<u64> {
    let mut n: u64 = 0;
    for &c in h[at..at + width].iter().skip_while(|&&c| c == b' ') {
        match c {
            b'0'..=b'7' => n = (n << 3) | (c - b'0') as u64,
            b' ' | 0 => break,
            _ => return None,
        }
    }
    Some(n)
}

/// What the header's checksum is: the sum of its trytes as bytes, with
/// its own field counted as spaces.
fn checksum(h: &Header) -> u64 {
    let field = CHKSUM.0..CHKSUM.0 + CHKSUM.1;
    h.iter()
        .enumerate()
        .map(|(i, &c)| if field.contains(&i) { b' ' as u64 } else { c as u64 })
        .sum()
}

/// A member's name, prefix and name joined, into `buf`.
fn member_name<'a>(h: &Header, buf: &'a mut [u8; 256]) -> &'a [u8] {
    let field = |(at, width): (usize, usize)| {
        let f = &h[at..at + width];
        &f[..f.iter().position(|&c| c == 0).unwrap_or(width)]
    };
    let (prefix, name) = (field(PREFIX), field(NAME));
    let mut n = 0;
    if !prefix.is_empty() {
        buf[..prefix.len()].copy_from_slice(prefix);
        buf[prefix.len()] = b'/';
        n = prefix.len() + 1;
    }
    buf[n..n + name.len()].copy_from_slice(name);
    &buf[..n + name.len()]
}

/// The names in directory `path`, "." and ".." left out, each ended
/// with a 0, read whole before the directory is closed: a program has
/// nine descriptors, too few to keep one open per level.
fn names(path: &[u8]) -> io::Result<Vec<u8>> {
    let mut names: Vec<u8> = Vec::new();
    let dir = File::open(path)?;
    let mut name = [0u8; sys::NAME_MAX as usize + 1];
    while let Some(n) = dir.read_name(&mut name)? {
        if n != b"." && n != b".." {
            names.extend_from_slice(n);
            names.push(0);
        }
    }
    Ok(names)
}

impl Tar<'_> {
    #[inline(never)]
    fn complain(&mut self, what: &[u8], e: &io::Error) {
        Line::new().str("tar: ").bytes(what).str(": ").error(e).eprint();
        self.failed = true;
    }

    #[inline(never)]
    fn say(&self, name: &[u8]) {
        let mut line = Line::new();
        line.bytes(name);
        if self.to_stderr {
            line.eprint();
        } else {
            let _ = line.print();
        }
    }

    // --- -c ---------------------------------------------------------------------

    /// Archive each PATH, and all a directory holds, a directory before
    /// its entries. The paths still to archive wait on a stack, rather
    /// than in a recursion: the program's stack is the lower half of its
    /// page, and a header is a record of 512.
    fn create(&mut self, out: &mut Archive, paths: &[&str]) -> io::Result<()> {
        let mut todo: Vec<Vec<u8>> = paths.iter().rev().map(|p| Vec::from(p.as_bytes())).collect();
        while let Some(path) = todo.pop() {
            if !self.add(out, &path)? {
                continue;
            }
            let names = match names(&path) {
                Ok(n) => n,
                Err(e) => {
                    self.complain(&path, &e);
                    continue;
                }
            };
            // Last name first onto the stack, so the first comes off first.
            for name in names.split(|&c| c == 0).filter(|n| !n.is_empty()).rev() {
                let mut child = path.clone();
                if child.last() != Some(&b'/') {
                    child.push(b'/');
                }
                child.extend_from_slice(name);
                todo.push(child);
            }
        }
        Ok(())
    }

    /// Archive `path`: true if it is a directory, whose entries are next.
    #[inline(never)]
    fn add(&mut self, out: &mut Archive, path: &[u8]) -> io::Result<bool> {
        let meta = match fs::metadata(path) {
            Ok(m) => m,
            Err(e) => {
                self.complain(path, &e);
                return Ok(false);
            }
        };
        if Some(meta.ino()) == self.archive_ino {
            // As GNU tar: a note, not a failure.
            Line::new().str("tar: ").bytes(path).str(": is the archive; not dumped").eprint();
            return Ok(false);
        }
        // The name in the archive: no leading /, and a directory's ends with /.
        let start = path.iter().position(|&c| c != b'/').unwrap_or(path.len());
        let mut name: Vec<u8> = Vec::from(&path[start..]);
        if meta.is_dir() && name.last() != Some(&b'/') {
            name.push(b'/');
        }
        let mut h: Header = [0; RECORD];
        if !self.place_name(&mut h, &name) {
            let e = io::Error::new(io::ErrorKind::InvalidInput, "name too long for the archive");
            self.complain(path, &e);
            return Ok(false);
        }
        if self.verbose {
            self.say(&name);
        }
        let (kind, size) = if meta.is_dir() { (DIRECTORY, 0) } else { (REGULAR, meta.len()) };
        octal(&mut h, MODE, meta.mode() as u64);
        octal(&mut h, UID, meta.uid().max(0) as u64);
        octal(&mut h, GID, meta.gid().max(0) as u64);
        octal(&mut h, SIZE, size);
        octal(&mut h, MTIME, meta.modified().map_or(0, |t| t.unix_seconds().max(0) as u64));
        h[TYPEFLAG] = kind;
        h[MAGIC.0..MAGIC.0 + MAGIC.1].copy_from_slice(b"ustar\x0000");
        let sum = checksum(&h);
        octal(&mut h, (CHKSUM.0, 7), sum); // six digits, a 0, then a space
        h[CHKSUM.0 + 7] = b' ';

        if meta.is_dir() {
            out.write_all(&h)?;
            return Ok(true);
        }
        let mut file = match File::open(path) {
            Ok(f) => f,
            Err(e) => {
                self.complain(path, &e);
                return Ok(false);
            }
        };
        out.write_all(&h)?;
        // The data, record by record; a file that is shorter than it said
        // is padded, so the archive stays whole.
        let mut left = size;
        let mut short = false;
        while left > 0 {
            let mut rec: Header = [0; RECORD];
            if !short {
                let want = left.min(RECORD as u64) as usize;
                let mut n = 0;
                while n < want {
                    match file.read(&mut rec[n..want]) {
                        Ok(0) => break,
                        Ok(got) => n += got,
                        Err(e) => {
                            self.complain(path, &e);
                            break;
                        }
                    }
                }
                short = n < want;
            }
            out.write_all(&rec)?;
            left = left.saturating_sub(RECORD as u64);
        }
        Ok(false)
    }

    /// Put `name` in the header: whole in the name field, or split at a /
    /// into prefix and name. False if it cannot fit.
    fn place_name(&self, h: &mut Header, name: &[u8]) -> bool {
        if name.len() <= NAME.1 {
            h[..name.len()].copy_from_slice(name);
            return true;
        }
        // The first / that leaves at most 100 after it and 155 before.
        let split = (0..name.len()).find(|&i| name[i] == b'/' && name.len() - i - 1 <= NAME.1 && i <= PREFIX.1);
        let Some(i) = split else {
            return false;
        };
        h[PREFIX.0..PREFIX.0 + i].copy_from_slice(&name[..i]);
        h[..name.len() - i - 1].copy_from_slice(&name[i + 1..]);
        true
    }

    // --- -t and -x --------------------------------------------------------------

    /// Whether -x was asked for this member: no PATHs, or one that is the
    /// member or a directory holding it.
    fn wanted(&self, name: &[u8]) -> bool {
        let name = name.strip_suffix(b"/").unwrap_or(name);
        self.only.is_empty()
            || self.only.iter().any(|p| {
                let p = p.trim_end_matches('/').as_bytes();
                name == p || (name.starts_with(p) && name.get(p.len()) == Some(&b'/'))
            })
    }

    /// Read each member of the archive, listing or taking out.
    fn read(&mut self, from: &mut Archive, extract: bool) -> io::Result<()> {
        loop {
            let mut h: Header = [0; RECORD];
            if !read_full(from, &mut h)? || h.iter().all(|&c| c == 0) {
                return Ok(()); // the end, or its first empty record
            }
            let (Some(size), Some(sum)) = (read_octal(&h, SIZE), read_octal(&h, CHKSUM)) else {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "not a tar archive"));
            };
            if sum != checksum(&h) {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "a header's checksum is wrong"));
            }
            let mut buf = [0u8; 256];
            let name = member_name(&h, &mut buf);
            let kind = h[TYPEFLAG];
            let is_dir = kind == DIRECTORY || (kind != REGULAR && name.last() == Some(&b'/'));
            let records = size.div_ceil(RECORD as u64);
            if !extract {
                let mut line = Line::new();
                if self.verbose {
                    line.str(if is_dir { "d " } else { "- " }).num_right(size as i64, 8).byte(b' ');
                }
                line.bytes(name).print()?;
                self.skip(from, records)?;
                continue;
            }
            let start = name.iter().position(|&c| c != b'/').unwrap_or(name.len());
            let mut path: Vec<u8> = Vec::from(&name[start..]);
            if !self.wanted(&path) {
                self.skip(from, records)?;
                continue;
            }
            if path.split(|&c| c == b'/').any(|part| part == b"..") {
                let e = io::Error::new(io::ErrorKind::InvalidInput, "member name contains '..'");
                self.complain(&path, &e);
                self.skip(from, records)?;
                continue;
            }
            if self.verbose {
                self.say(&path);
            }
            while path.last() == Some(&b'/') {
                path.pop();
            }
            if path.is_empty() {
                self.skip(from, records)?;
                continue;
            }
            if is_dir {
                self.make_dirs(&path, true);
                self.skip(from, records)?;
                restore(&h, &path);
            } else if kind == REGULAR || kind == 0 {
                self.make_dirs(&path, false);
                self.extract_file(from, &path, size)?;
                restore(&h, &path);
            } else {
                let e = io::Error::new(io::ErrorKind::Unsupported, "not a file or directory; skipped");
                self.complain(&path, &e);
                self.skip(from, records)?;
            }
        }
    }

    fn skip(&mut self, from: &mut Archive, records: u64) -> io::Result<()> {
        let mut rec: Header = [0; RECORD];
        for _ in 0..records {
            if !read_full(from, &mut rec)? {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive ends inside a member"));
            }
        }
        Ok(())
    }

    /// Make the directories `path` lies in, and with `whole` the last part
    /// too; one there already is fine.
    fn make_dirs(&mut self, path: &[u8], whole: bool) {
        for (i, &c) in path.iter().enumerate() {
            if c == b'/' && i > 0 {
                let _ = fs::create_dir(&path[..i]);
            }
        }
        if whole {
            if let Err(e) = fs::create_dir(path) {
                if !fs::metadata(path).is_ok_and(|m| m.is_dir()) {
                    self.complain(path, &e);
                }
            }
        }
    }

    fn extract_file(&mut self, from: &mut Archive, path: &[u8], size: u64) -> io::Result<()> {
        let mut file = match File::create(path) {
            Ok(f) => Some(f),
            Err(e) => {
                self.complain(path, &e);
                None
            }
        };
        let mut left = size;
        while left > 0 {
            let mut rec: Header = [0; RECORD];
            if !read_full(from, &mut rec)? {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive ends inside a member"));
            }
            let n = left.min(RECORD as u64) as usize;
            if let Some(f) = &mut file {
                if let Err(e) = f.write_all(&rec[..n]) {
                    self.complain(path, &e);
                    file = None;
                }
            }
            left -= n as u64;
        }
        Ok(())
    }
}

/// Give what was taken out the header's mode and modification time,
/// as far as the filesystem allows.
fn restore(h: &Header, path: &[u8]) {
    if let Some(mode) = read_octal(h, MODE) {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode as u32));
    }
    if let Some(secs) = read_octal(h, MTIME) {
        let t = SystemTime::from_unix_seconds(secs as i64);
        let _ = fs::set_times(path, fs::FileTimes::new().set_modified(t));
    }
}

fn usage() -> i32 {
    Line::new().str("usage: tar -c|-t|-x [-v] [-f ARCHIVE] [PATH]...").eprint();
    2
}

fn run() -> i32 {
    let mut args = env::args().skip(1).peekable();
    let (mut mode, mut verbose, mut archive) = (0u8, false, "-");
    let mut first = true;
    // The first argument's letters need no dash; f takes the next argument.
    while let Some(arg) = args.next_if(|a| a.starts_with('-') && a.len() > 1 || first) {
        first = false;
        for c in arg.trim_start_matches('-').bytes() {
            match c {
                b'c' | b't' | b'x' if mode == 0 || mode == c => mode = c,
                b'v' => verbose = true,
                b'f' => match args.next() {
                    Some(name) => archive = name,
                    None => return usage(),
                },
                _ => return usage(),
            }
        }
    }
    if mode == 0 {
        return usage();
    }
    let paths: Vec<&str> = args.collect();
    let std = archive == "-";
    let mut tar = Tar { verbose, to_stderr: std && mode == b'c', archive_ino: None, only: &[], failed: false };

    let done = if mode == b'c' {
        if paths.is_empty() {
            Line::new().str("tar: refusing to make an empty archive").eprint();
            return 2;
        }
        let mut out = if std {
            Archive::Std
        } else {
            match File::create(archive) {
                Ok(f) => {
                    tar.archive_ino = fs::metadata(archive).ok().map(|m| m.ino());
                    Archive::File(f)
                }
                Err(e) => {
                    tar.complain(archive.as_bytes(), &e);
                    return 2;
                }
            }
        };
        tar.create(&mut out, &paths)
            .and_then(|()| out.write_all(&[0; 2 * RECORD])).and_then(|()| out.flush())
    } else {
        let mut from = if std {
            Archive::Std
        } else {
            match File::open(archive) {
                Ok(f) => Archive::File(f),
                Err(e) => {
                    tar.complain(archive.as_bytes(), &e);
                    return 2;
                }
            }
        };
        tar.only = &paths;
        tar.read(&mut from, mode == b'x').and_then(|()| io::stdout().flush())
    };
    if let Err(e) = done {
        tar.complain(archive.as_bytes(), &e);
    }
    if tar.failed { 2 } else { 0 }
}
