//! The file server (docs/filesystem.md): a process that owns the
//! filesystem on the disk and answers other processes' calls to open,
//! read, write, make and remove its files and directories. The
//! filesystem itself is lib/rust/tryfs, shared with the host's disk
//! tool; this is the protocol around it (FS_PROTOCOL, include/layout.s)
//! and the store under it, the block windows (win.rs).
//!
//! It registers as "fs" before it takes its first call, and takes one
//! call at a time. Each call is a transaction: it changes the tree in
//! fresh blocks and commits before the reply, so a call that is answered
//! is on the disk, and one that fails leaves the disk as it was.
//!
//! An open file is a record here whose index is a handle: open gives the
//! caller a kernel descriptor for it (SYS_GIVE), and reading, writing,
//! seeking and listing come as descriptor calls (IO_ operations) from
//! whoever holds a copy. The record goes when the kernel says no
//! descriptor names it any more (NOTE_CLOSED). Each process's current
//! directory is kept here too, and dropped when the kernel says the
//! process ended (NOTE_ENDED).

#![no_std]

mod sys;
mod win;

use tryfs::key::NAME_LEN;
use tryfs::layout::*;
use tryfs::ops::is_dots;
use tryfs::tree::Item;
use tryfs::{Fs, Inode, Key, Result, Store, Time};

use win::Windows;

const NF: usize = NFILE as usize;
const NP: usize = NPROC as usize;
const PATH: usize = PATH_MAX as usize + 1;

/// Where a directory's listing has got to.
#[derive(Clone, Copy, PartialEq)]
enum Cursor {
    Dot,
    DotDot,
    First,
    After,
}

#[derive(Clone, Copy)]
struct File {
    ino: i64, // NO_INO when the record is free
    pos: i64,
    flags: i32,
    cursor: Cursor,
    after: Key,
}

/// What a call on an open file needs of it, without its directory
/// cursor's key, which is big to copy.
#[derive(Clone, Copy)]
struct Basics {
    ino: i64,
    pos: i64,
    flags: i32,
}

const CLOSED: File = File { ino: NO_INO, pos: 0, flags: 0, cursor: Cursor::Dot, after: Key::empty() };

struct Server {
    fs: Fs<Windows>,
    files: [File; NF],
    cwd: [i64; NP], // each process's current directory; NO_INO for the root
    caller: i64,
    whose: i64,
    /// The call's words after its operation.
    a: [i64; 3],
}

/// The server's state, about 14,000 trytes (most of it the bit sets of
/// which blocks are in use), in its heap rather than its image, where
/// those zeros would take a page and so two of RAM. brk's pages are
/// zeroed, so only what is not zero in a new server is set.
fn server() -> &'static mut Server {
    let at = (HEAP_START + 7) & !7; // as Rust aligns an i64
    let end = at + core::mem::size_of::<Server>() as i64;
    if sys::call(SYS_BRK, end, 0, 0, 0, 0) < 0 {
        sys::exit(E_NOMEM);
    }
    let p = at as usize as *mut Server;
    unsafe {
        (&raw mut (*p).fs.store).write(Windows::new());
        for k in 0..NF {
            (&raw mut (*p).files[k]).write(CLOSED);
        }
        let srv = &mut *p;
        srv.fs.reset();
        srv
    }
}

/// A path, as code points.
struct Path {
    len: usize,
    c: [i32; PATH],
}

impl Path {
    const fn new() -> Path {
        Path { len: 0, c: [0; PATH] }
    }

    fn cps(&self) -> &[i32] {
        &self.c[..self.len]
    }
}

/// The file block a position is in, and where in it: positions are
/// below 2^31, so u32 division, which the machine does itself, serves
/// (an i64's takes a long loop).
fn in_block(pos: i64) -> (i64, i64) {
    let p = pos as u32;
    ((p / PAGE as u32) as i64, (p % PAGE as u32) as i64)
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    sys::exit(E_IO)
}

/// Start here (user/fsd.s): find the disk server, waiting for it to
/// start, then register, then answer calls for ever. A second file
/// server finds the name taken, and leaves with why.
#[unsafe(no_mangle)]
pub extern "C" fn fsd_main() -> ! {
    let srv = server();
    sys::call(SYS_NAME, sys::addr(b"fsd\0".as_ptr()), 0, 0, 0, 0);
    let disk = sys::call(SYS_LOOKUP, sys::addr(b"disk\0".as_ptr()), LOOKUP_WAIT, 0, 0, 0);
    if disk >= 0 && sys::more(0) == DISK_PROTOCOL {
        srv.fs.store.disk = disk;
    }
    let r = sys::call(SYS_REGISTER, sys::addr(b"fs\0".as_ptr()), FS_PROTOCOL, 0, 0, 0);
    if r < 0 {
        sys::exit(r);
    }
    loop {
        srv.serve();
    }
}

impl Server {
    /// Take one call or notice and answer it.
    fn serve(&mut self) {
        let who = sys::call(SYS_RECEIVE, 0, 0, 0, 0, 0);
        let op = sys::more(0);
        self.a = [sys::more(1), sys::more(2), sys::more(3)];
        if who == FROM_KERNEL {
            self.notice(op, self.a[0]);
            return;
        }
        self.caller = who;
        self.whose = sys::more(4);
        // The time, for what the call changes: a read changes nothing
        // but now and then an access time (Server::accessed).
        if !matches!(op, IO_READ | IO_LSEEK | IO_READDIR | FS_STAT | FS_GETCWD | FS_STATFS) {
            self.stamp();
        }
        let mut result = self.call(op);
        match result {
            Ok(_) => {
                if let Err(e) = self.fs.commit() {
                    result = Err(e);
                }
            }
            Err(_) => self.fs.abort(),
        }
        let answer = match result {
            Ok(v) => v,
            Err(e) => e,
        };
        sys::call(SYS_REPLY, self.caller, answer, 0, 0, 0);
    }

    /// Take the time of day as the call's.
    fn stamp(&mut self) {
        let (secs, nanos) = sys::clock();
        self.fs.now = Time { secs, nanos };
    }

    /// The file was read: bring its access time up if it is due
    /// (relatime), taking the time only then.
    fn accessed(&mut self, ino: i64) -> Result<()> {
        if self.fs.atime_due(ino)? {
            self.stamp();
            self.fs.accessed(ino)?;
        }
        Ok(())
    }

    /// A handle no descriptor names any more: its file is closed. A
    /// process ended: forget its current directory.
    fn notice(&mut self, what: i64, x: i64) {
        if what == NOTE_CLOSED && (0..NF as i64).contains(&x) {
            self.files[x as usize].ino = NO_INO;
        } else if what == NOTE_ENDED && (0..NP as i64).contains(&x) {
            self.cwd[x as usize] = NO_INO;
        }
    }

    fn call(&mut self, op: i64) -> Result<i64> {
        if op < 0 {
            return self.io(op);
        }
        self.enter()?;
        match op {
            FS_OPEN => self.open(),
            FS_STAT => self.stat(),
            FS_SPAWN => self.spawn(),
            FS_UNLINK => self.unlink(),
            FS_MKDIR => self.mkdir(),
            FS_RMDIR => self.rmdir(),
            FS_CHDIR => self.chdir(),
            FS_GETCWD => self.getcwd(),
            FS_STATFS => self.statfs(),
            FS_RENAME => self.rename(),
            FS_UTIMES => self.utimes(),
            FS_CHMOD => self.chmod(),
            FS_CHOWN => self.chown(),
            _ => Err(E_INVAL),
        }
    }

    /// A descriptor call, from a descriptor this server gave: the handle
    /// in the first word.
    fn io(&mut self, op: i64) -> Result<i64> {
        let h = self.a[0];
        if !(0..NF as i64).contains(&h) || self.files[h as usize].ino == NO_INO {
            return Err(E_BADF);
        }
        let h = h as usize;
        if op == IO_LSEEK {
            return self.lseek(h);
        }
        self.enter()?;
        match op {
            IO_READ => self.read(h),
            IO_WRITE => self.write(h),
            IO_READDIR => self.readdir(h),
            _ => Err(E_INVAL),
        }
    }

    /// Make sure the disk holds a filesystem, mounting it the first time:
    /// E_NOFS if it does not.
    fn enter(&mut self) -> Result<()> {
        if !self.fs.mounted {
            self.fs.mount().map_err(|e| if e == E_IO || e == E_NOMEM { e } else { E_NOFS })?;
        }
        Ok(())
    }

    /// The caller's process's current directory.
    fn cwd(&self) -> i64 {
        match self.cwd.get(self.whose as usize) {
            Some(&NO_INO) | None => ROOT_INO,
            Some(&d) => d,
        }
    }

    /// Copy the path at `at` in the caller's memory: E_FAULT if it is not
    /// all there, E_NAMETOOLONG if it has no 0 within PATH_MAX + 1 trytes.
    fn path_in(&mut self, at: i64, out: &mut Path) -> Result<()> {
        let buf = sys::pathbuf();
        let mut n = PATH;
        if sys::call(SYS_COPYIN, self.caller, at, sys::addr(buf), PATH as i64, 0) != 0 {
            // It may end near the end of the caller's memory: a tryte at
            // a time, up to its 0.
            n = 0;
            loop {
                let r = sys::call(SYS_COPYIN, self.caller, at + n as i64, sys::addr(buf) + n as i64, 1, 0);
                if r != 0 {
                    return Err(E_FAULT);
                }
                if self.tryte_at(n) == 0 {
                    break;
                }
                n += 1;
                if n == PATH {
                    return Err(E_NAMETOOLONG);
                }
            }
        }
        for i in 0..n {
            let c = self.tryte_at(i);
            if c == 0 {
                out.len = i;
                return Ok(());
            }
            out.c[i] = c as i32;
        }
        Err(E_NAMETOOLONG)
    }

    /// Tryte `i` of the path buffer.
    fn tryte_at(&self, i: usize) -> i64 {
        // The buffer's first word is centred one tryte past its start.
        let w = sys::word(sys::pathbuf().wrapping_add(1), i / 3);
        sys::trytes(w)[i % 3]
    }

    /// The call's path argument `k`, followed up to its last name.
    fn last(&mut self, k: usize, path: &mut Path) -> Result<tryfs::ops::Last> {
        self.path_in(self.a[k], path)?;
        let cwd = self.cwd();
        self.fs.walk_path(cwd, path.cps())
    }

    /// The inode the call's path argument `k` names.
    #[inline(never)]
    fn resolve(&mut self, k: usize) -> Result<i64> {
        let mut path = Path::new();
        let path = &mut path;
        self.path_in(self.a[k], path)?;
        let cwd = self.cwd();
        self.fs.resolve(cwd, path.cps())
    }

    /// E_BUSY if some process has inode `ino` open or as its current
    /// directory: a descriptor or a directory must not name a gone inode.
    fn basics(&self, h: usize) -> Basics {
        let f = &self.files[h];
        Basics { ino: f.ino, pos: f.pos, flags: f.flags }
    }

    fn busy(&self, ino: i64) -> Result<()> {
        if self.files.iter().any(|f| f.ino == ino) || self.cwd.contains(&ino) {
            return Err(E_BUSY);
        }
        Ok(())
    }

    /// Copy `n` trytes from `from` here to `to` in the caller's memory:
    /// E_FAULT if they do not all fit there.
    fn copy_out(&self, from: i64, to: i64, n: i64) -> Result<()> {
        if sys::call(SYS_COPYOUT, self.caller, from, to, n, 0) != 0 {
            return Err(E_FAULT);
        }
        Ok(())
    }

    /// E_FAULT unless `at` is a word's address.
    fn aligned(at: i64) -> Result<()> {
        if at < 0 || (at as u32) % 3 != 0 {
            return Err(E_FAULT);
        }
        Ok(())
    }

    // --- the FS_ calls ------------------------------------------------------

    /// open(path, flags): the caller's lowest free descriptor, at the start
    /// of the file or directory, for reading, writing or both (flags mod
    /// 3). O_CREAT makes an empty file if the name is free, O_TRUNC
    /// empties a file opened for writing, and O_APPEND writes at the end
    /// each time. A directory opens for reading only.
    #[inline(never)]
    fn open(&mut self) -> Result<i64> {
        let h = self.files.iter().position(|f| f.ino == NO_INO).ok_or(E_MFILE)?;
        if !(0..81).contains(&self.a[1]) {
            return Err(E_INVAL);
        }
        let flags = self.a[1] as i32; // i32, whose division is the machine's
        if (flags / 3) % 3 > 1 || (flags / 9) % 3 > 1 {
            return Err(E_INVAL);
        }
        let access = flags % 3;
        let creat = (flags / O_CREAT as i32) % 3 == 1;
        let trunc = (flags / O_TRUNC as i32) % 3 == 1;
        let mut path = Path::new();
        let path = &mut path;
        let mut made = false;
        let ino = if creat {
            let last = self.last(0, path)?;
            let name = &path.c[last.start..last.end];
            if name.is_empty() {
                last.dir // the root, which is there
            } else {
                let dir = self.fs.iget(last.dir)?;
                match self.fs.lookup(&dir, name)? {
                    Some(ino) => ino,
                    None => {
                        made = true;
                        self.fs.create(last.dir, name, T_FILE, MODE_FILE)?.ino
                    }
                }
            }
        } else {
            self.resolve(0)?
        };
        let node = self.fs.iget(ino)?;
        if node.is_dir() && access != O_RDONLY as i32 {
            return Err(E_ISDIR);
        }
        if !node.is_dir() && access != O_RDONLY as i32 && trunc && !made && node.size > 0 {
            self.fs.truncate(ino)?;
        }
        // On the disk before the caller has a descriptor for it.
        self.fs.commit()?;
        self.files[h] = File { ino, pos: 0, flags, cursor: Cursor::Dot, after: Key::empty() };
        let fd = sys::call(SYS_GIVE, self.caller, h as i64, 0, 0, 0);
        if fd < 0 {
            self.files[h].ino = NO_INO; // E_MFILE: the caller has none free
        }
        Ok(fd)
    }

    /// stat(path, buffer): what path names, as the ST_ words at the buffer.
    #[inline(never)]
    fn stat(&mut self) -> Result<i64> {
        let to = self.a[1];
        Self::aligned(to)?;
        let ino = self.resolve(0)?;
        let node = self.fs.iget(ino)?;
        let blocks = self.blocks_of(ino)?;
        let out = sys::words();
        for i in 0..(STAT / 3) as usize {
            sys::set_word(out, i, 0);
        }
        let put = |at: i64, w: i64| sys::set_word(out, (at / 3) as usize, w);
        put(ST_INO, ino);
        put(ST_TYPE, node.typ);
        put(ST_LINKS, node.links);
        put(ST_SIZE, node.size);
        put(ST_MODE, node.mode);
        put(ST_UID, node.uid);
        put(ST_GID, node.gid);
        for (at, t) in [(ST_ATIME, node.atime), (ST_MTIME, node.mtime), (ST_CTIME, node.ctime), (ST_BTIME, node.btime)] {
            put(at, t.secs);
            put(at + 3, t.nanos);
        }
        put(ST_BLOCKS, blocks);
        self.copy_out(sys::addr(out) + ST_INO - 1, to + ST_INO - 1, STAT)?;
        Ok(0)
    }

    /// The data blocks inode `ino` has.
    fn blocks_of(&mut self, ino: i64) -> Result<i64> {
        let mut it = Item::new();
        let mut n = 0;
        let mut k = Key::extent(ino, -1);
        while self.fs.seek(&k, true, &mut it)? && it.key.ino() == ino && it.key.kind() == K_EXTENT {
            n += it.value[EX_LEN as usize];
            k = it.key;
        }
        Ok(n)
    }

    /// spawnf(path, args, n): start the program file path names as the
    /// caller's child, with the n trytes of arguments at args in the
    /// caller's memory. Its blocks are read into windows 0 on, where
    /// spawnw finds them. The child starts in the caller's current
    /// directory.
    #[inline(never)]
    fn spawn(&mut self) -> Result<i64> {
        let ino = self.resolve(0)?;
        let node = self.fs.iget(ino)?;
        if node.is_dir() || node.size < EXEC_HEAD {
            return Err(E_NOEXEC);
        }
        let first = self.fs.bmap(ino, 0)?;
        if first == NO_BLOCK {
            return Err(E_NOEXEC);
        }
        let s = self.fs.store.load(first)?;
        let magic = self.fs.store.word(s, 0);
        let size = self.fs.store.word(s, 1); // EXEC_SIZE
        if magic != EXEC_MAGIC || !(0..=EXEC_MAX).contains(&size) || size + EXEC_HEAD > node.size {
            return Err(E_NOEXEC);
        }
        let n = (size + EXEC_HEAD + PAGE - 1) / PAGE;
        let mut blocks = [NO_BLOCK; NWIN as usize];
        for fb in 0..n {
            let b = self.fs.bmap(ino, fb)?;
            if b == NO_BLOCK {
                return Err(E_NOEXEC); // a hole: not one the tools make
            }
            blocks[fb as usize] = b;
        }
        // What the call changed (its access time) goes first: the windows
        // are about to hold the program, so none may be dirty.
        self.accessed(ino)?;
        self.fs.commit()?;
        for fb in 0..n as usize {
            self.fs.store.read_into(blocks[fb], fb)?;
        }
        let child = sys::call(SYS_SPAWNW, 0, self.caller, self.a[1], self.a[2], 0);
        if child < 0 {
            return Err(child);
        }
        let here = self.cwd.get(self.whose as usize).copied().unwrap_or(NO_INO);
        if let Some(c) = self.cwd.get_mut(child as usize) {
            *c = here;
        }
        Ok(child)
    }

    /// unlink(path): remove a file's name, and the file once it has no
    /// other. A directory is E_ISDIR, and a file some process has open
    /// E_BUSY.
    #[inline(never)]
    fn unlink(&mut self) -> Result<i64> {
        let mut path = Path::new();
        let path = &mut path;
        let last = self.last(0, path)?;
        let name = &path.c[last.start..last.end];
        if name.is_empty() {
            return Err(E_ISDIR); // the root
        }
        if is_dots(name) {
            return Err(E_INVAL);
        }
        let dir = self.fs.iget(last.dir)?;
        let ino = self.fs.lookup(&dir, name)?.ok_or(E_NOENT)?;
        if !self.fs.iget(ino)?.is_dir() {
            self.busy(ino)?;
        }
        self.fs.unlink(last.dir, name)?;
        Ok(0)
    }

    /// mkdir(path): a new, empty directory.
    #[inline(never)]
    fn mkdir(&mut self) -> Result<i64> {
        let mut path = Path::new();
        let path = &mut path;
        let last = self.last(0, path)?;
        let name = &path.c[last.start..last.end];
        if name.is_empty() {
            return Err(E_EXIST); // the root
        }
        self.fs.create(last.dir, name, T_DIR, MODE_DIR)?;
        Ok(0)
    }

    /// rmdir(path): remove a directory holding nothing but . and .. . One
    /// a process has open, or as its current directory, is E_BUSY, as is
    /// the root.
    #[inline(never)]
    fn rmdir(&mut self) -> Result<i64> {
        let mut path = Path::new();
        let path = &mut path;
        let last = self.last(0, path)?;
        let name = &path.c[last.start..last.end];
        if name.is_empty() {
            return Err(E_BUSY);
        }
        if is_dots(name) {
            return Err(E_INVAL);
        }
        let dir = self.fs.iget(last.dir)?;
        if let Some(ino) = self.fs.lookup(&dir, name)? {
            // Not empty before busy, as the shell's own directory with
            // files in it is "not empty" on Unix too.
            if self.fs.iget(ino)?.is_dir() && self.fs.dir_empty(ino)? {
                self.busy(ino)?;
            }
        }
        self.fs.rmdir(last.dir, name)?;
        Ok(0)
    }

    /// chdir(path): make the directory path names the caller's current one.
    #[inline(never)]
    fn chdir(&mut self) -> Result<i64> {
        let ino = self.resolve(0)?;
        if !self.fs.iget(ino)?.is_dir() {
            return Err(E_NOTDIR);
        }
        if let Some(c) = self.cwd.get_mut(self.whose as usize) {
            *c = ino;
        }
        Ok(0)
    }

    /// getcwd(buffer, n): the path from the root to the caller's current
    /// directory, ended with 0, to the buffer if n trytes hold it: its
    /// length. It is put together from the end back, a name at a time,
    /// each directory's parent's entry for it giving its name.
    #[inline(never)]
    fn getcwd(&mut self) -> Result<i64> {
        let mut path = Path::new();
        let path = &mut path;
        let mut start = PATH - 1; // path.c[start..PATH - 1] so far
        let mut dir = self.cwd();
        let mut name = [0; NAME_LEN];
        while dir != ROOT_INO {
            let n = self.fs.name_in_parent(dir, &mut name)?;
            if start < n + 1 {
                return Err(E_NAMETOOLONG);
            }
            start -= n;
            path.c[start..start + n].copy_from_slice(&name[..n]);
            start -= 1;
            path.c[start] = '/' as i32;
            dir = self.fs.iget(dir)?.parent;
        }
        if start == PATH - 1 {
            start -= 1;
            path.c[start] = '/' as i32; // the root alone is /
        }
        let len = (PATH - 1 - start) as i64;
        if len + 1 > self.a[1] {
            return Err(E_NOROOM);
        }
        path.c[PATH - 1] = 0;
        let buf = self.out_trytes(&path.c[start..]);
        self.copy_out(buf, self.a[0], len + 1)?;
        Ok(len)
    }

    /// Lay code points out as trytes in the words buffer: its first tryte.
    fn out_trytes(&self, cps: &[i32]) -> i64 {
        let out = sys::words();
        let c = |i: usize| cps.get(i).copied().unwrap_or(0) as i64;
        for j in 0..cps.len().div_ceil(3) {
            let w = c(3 * j) + 19683 * (c(3 * j + 1) + 19683 * c(3 * j + 2));
            sys::set_word(out, j, w);
        }
        sys::addr(out) - 1
    }

    /// statfs(buffer): how full the disk is, as the SF_ words at the
    /// buffer.
    #[inline(never)]
    fn statfs(&mut self) -> Result<i64> {
        let to = self.a[0];
        Self::aligned(to)?;
        let out = sys::words();
        let free = self.fs.free_blocks();
        let ifree = free * INODES_PER_BLOCK;
        let put = |at: i64, w: i64| sys::set_word(out, (at / 3) as usize, w);
        put(SF_BLOCKS, self.fs.blocks);
        put(SF_BFREE, free);
        put(SF_INODES, self.fs.inodes + ifree);
        put(SF_IFREE, ifree);
        self.copy_out(sys::addr(out) + SF_BLOCKS - 1, to + SF_BLOCKS - 1, STATFS)?;
        Ok(0)
    }

    /// rename(from, to): give what from names the name to, replacing a
    /// file of that name unless a process has it open (E_BUSY). The root
    /// can neither move (E_BUSY) nor be replaced (E_EXIST).
    #[inline(never)]
    fn rename(&mut self) -> Result<i64> {
        let mut from = Path::new();
        let from = &mut from;
        let a = self.last(0, from)?;
        if a.start == a.end {
            return Err(E_BUSY);
        }
        let mut to = Path::new();
        let to = &mut to;
        let b = self.last(1, to)?;
        if b.start == b.end {
            return Err(E_EXIST);
        }
        let (fname, tname) = (&from.c[a.start..a.end], &to.c[b.start..b.end]);
        let tdir = self.fs.iget(b.dir)?;
        if !is_dots(tname) {
            if let Some(old) = self.fs.lookup(&tdir, tname)? {
                let src = self.fs.iget(a.dir)?;
                if self.fs.lookup(&src, fname)? != Some(old) {
                    self.busy(old)?;
                }
            }
        }
        self.fs.rename(a.dir, fname, b.dir, tname)?;
        Ok(0)
    }

    /// utimes(path, times): its access and modification times.
    #[inline(never)]
    fn utimes(&mut self) -> Result<i64> {
        let at = self.a[1];
        Self::aligned(at)?;
        let ino = self.resolve(0)?;
        let buf = sys::words();
        if sys::call(SYS_COPYIN, self.caller, at - 1, sys::addr(buf) - 1, 12, 0) != 0 {
            return Err(E_FAULT);
        }
        let mut node = self.fs.iget(ino)?;
        let now = self.fs.now;
        let set = |t: &mut Time, i: usize| -> Result<()> {
            let (secs, nanos) = (sys::word(buf, i), sys::word(buf, i + 1));
            match nanos {
                UTIME_OMIT => {}
                UTIME_NOW => *t = now,
                0..=999_999_999 => *t = Time { secs, nanos },
                _ => return Err(E_INVAL),
            }
            Ok(())
        };
        set(&mut node.atime, 0)?;
        set(&mut node.mtime, 2)?;
        node.ctime = now;
        self.fs.iput(&node)?;
        Ok(0)
    }

    /// chmod(path, mode): its permissions.
    #[inline(never)]
    fn chmod(&mut self) -> Result<i64> {
        let mode = self.a[1];
        if !(0..=MODE_MAX).contains(&mode) {
            return Err(E_INVAL);
        }
        self.change(|node| node.mode = mode)
    }

    /// chown(path, uid, gid): its owner and group.
    #[inline(never)]
    fn chown(&mut self) -> Result<i64> {
        let (uid, gid) = (self.a[1], self.a[2]);
        if (uid < 0 && uid != KEEP_ID) || (gid < 0 && gid != KEEP_ID) {
            return Err(E_INVAL);
        }
        self.change(|node| {
            if uid != KEEP_ID {
                node.uid = uid;
            }
            if gid != KEEP_ID {
                node.gid = gid;
            }
        })
    }

    /// Change what the path names, which changes its change time.
    fn change(&mut self, f: impl FnOnce(&mut Inode)) -> Result<i64> {
        let ino = self.resolve(0)?;
        let mut node = self.fs.iget(ino)?;
        f(&mut node);
        node.ctime = self.fs.now;
        self.fs.iput(&node)?;
        Ok(0)
    }

    // --- the descriptor calls -------------------------------------------------

    /// read(handle, buffer, n): copy up to n trytes from the position,
    /// no further than its block's end: how many, 0 at the end.
    #[inline(never)]
    fn read(&mut self, h: usize) -> Result<i64> {
        let f = self.basics(h);
        if f.flags % 3 == O_WRONLY as i32 {
            return Err(E_BADF);
        }
        let n = self.a[2];
        if n < 0 {
            return Err(E_INVAL);
        }
        let node = self.fs.iget(f.ino)?;
        if node.is_dir() {
            return Err(E_ISDIR);
        }
        let (fb, off) = in_block(f.pos);
        let count = n.min(node.size - f.pos).min(PAGE - off);
        if count <= 0 {
            return Ok(0);
        }
        let b = self.fs.bmap(f.ino, fb)?;
        if b == NO_BLOCK {
            self.zeros_out(self.a[1], count)?;
        } else {
            let s = self.fs.store.load(b)?;
            self.copy_out(win::first_tryte(s) + off, self.a[1], count)?;
        }
        self.accessed(f.ino)?;
        self.files[h].pos += count;
        Ok(count)
    }

    /// Copy `n` zeros to `to` in the caller's memory: a hole.
    fn zeros_out(&self, to: i64, n: i64) -> Result<()> {
        static ZEROS: [u8; 729] = [0; 729];
        let mut done = 0;
        while done < n {
            let k = (n - done).min(ZEROS.len() as i64);
            self.copy_out(sys::addr(ZEROS.as_ptr()), to + done, k)?;
            done += k;
        }
        Ok(())
    }

    /// write(handle, buffer, n): copy up to n trytes from the buffer to
    /// the file at the position (its end, with O_APPEND), no further than
    /// the end of the block the position is in: how many.
    #[inline(never)]
    fn write(&mut self, h: usize) -> Result<i64> {
        let f = self.basics(h);
        if f.flags % 3 == O_RDONLY as i32 {
            return Err(E_BADF);
        }
        let n = self.a[2];
        if n < 0 {
            return Err(E_INVAL);
        }
        if n == 0 {
            return Ok(0);
        }
        let mut node = self.fs.iget(f.ino)?;
        let pos = if (f.flags / O_APPEND as i32) % 3 == 1 { node.size } else { f.pos };
        let (fb, off) = in_block(pos);
        let count = n.min(PAGE - off);
        let (b, _) = self.fs.bmap_alloc(f.ino, fb)?;
        node = self.fs.iget(f.ino)?;
        node.size = node.size.max(pos + count);
        node.mtime = self.fs.now;
        node.ctime = self.fs.now;
        self.fs.iput(&node)?;
        // Every change is made: the trytes last, so that a buffer that is
        // not all the caller's fails the call with nothing changed.
        let s = self.fs.store.load(b)?;
        if sys::call(SYS_COPYIN, self.caller, self.a[1], win::first_tryte(s) + off, count, 0) != 0 {
            return Err(E_FAULT);
        }
        self.fs.store.mark_dirty(s);
        self.files[h].pos = pos + count;
        Ok(count)
    }

    /// lseek(handle, offset, whence): the position, set from the start,
    /// where it is or the end. It may pass the end of a file, but not its
    /// start; a directory may only go back to its start.
    #[inline(never)]
    fn lseek(&mut self, h: usize) -> Result<i64> {
        let f = self.basics(h);
        let from = match self.a[2] {
            SEEK_SET => 0,
            SEEK_CUR => f.pos,
            SEEK_END => {
                self.enter()?;
                self.fs.iget(f.ino)?.size
            }
            _ => return Err(E_INVAL),
        };
        let pos = from + self.a[1];
        if pos < 0 {
            return Err(E_INVAL);
        }
        if pos == 0 {
            self.files[h].cursor = Cursor::Dot;
        }
        self.files[h].pos = pos;
        Ok(pos)
    }

    /// readdir(handle, buffer): the next entry of a directory, `.` and
    /// `..` first: its name to the buffer, NAME_MAX + 1 trytes, and its
    /// inode as the result; 0 at the end.
    #[inline(never)]
    fn readdir(&mut self, h: usize) -> Result<i64> {
        let f = self.files[h];
        let dir = self.fs.iget(f.ino)?;
        if !dir.is_dir() {
            return Err(E_NOTDIR);
        }
        let mut name = [0i32; NAME_LEN + 1];
        let (ino, n, next) = match f.cursor {
            Cursor::Dot => {
                name[0] = '.' as i32;
                (dir.ino, 1, Cursor::DotDot)
            }
            Cursor::DotDot => {
                name[0] = '.' as i32;
                name[1] = '.' as i32;
                (dir.parent, 2, Cursor::First)
            }
            _ => {
                let mut it = Item::new();
                let after = if f.cursor == Cursor::After { Some(&f.after) } else { None };
                if !self.fs.next_entry(dir.ino, after, &mut it)? {
                    return Ok(0);
                }
                let mut cps = [0; NAME_LEN];
                let n = it.key.name(&mut cps);
                name[..n].copy_from_slice(&cps[..n]);
                self.files[h].after = it.key;
                (it.value[DE_INO as usize], n, Cursor::After)
            }
        };
        name[n] = 0;
        let buf = self.out_trytes(&name);
        self.copy_out(buf, self.a[1], NAME_MAX + 1)?;
        self.files[h].cursor = next;
        self.files[h].pos += 1;
        Ok(ino)
    }
}
