//! Files and directories, from the file server (docs/kernel.md, Files),
//! as std::fs has them. A path is any `AsRef<[u8]>` (`&str`, `String`,
//! `&[u8]`): from the root with a leading /, else from the current
//! directory (`env::set_current_dir`).

use alloc::string::String;
use alloc::vec::Vec;

use crate::io::{self, Read, Seek, SeekFrom, Write};
use crate::sys::{self, CPath, FS, Words};

/// A descriptor this program owns: closed when it is dropped.
#[derive(Debug)]
pub struct OwnedFd(i32);

impl OwnedFd {
    /// Take ownership of descriptor `fd`.
    pub fn from_raw(fd: i32) -> OwnedFd {
        OwnedFd(fd)
    }

    pub fn raw(&self) -> i32 {
        self.0
    }

    /// The descriptor, no longer closed on drop.
    pub fn into_raw(self) -> i32 {
        let fd = self.0;
        core::mem::forget(self);
        fd
    }

    pub(crate) fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        io::read_fd(self.0, buf)
    }

    pub(crate) fn write(&self, buf: &[u8]) -> io::Result<usize> {
        io::write_fd(self.0, buf)
    }

    /// A descriptor call (SYS_IOCALL): operation `op` (an IO_ one).
    pub(crate) fn iocall(&self, op: i32, x: i32, y: i32) -> io::Result<i32> {
        sys::check(sys::call(sys::SYS_IOCALL, &[self.0, op, x, y]))
    }

    /// Keep it from children (FD_NOINHERIT), or let them have it.
    pub fn set_inherit(&self, inherit: bool) -> io::Result<()> {
        set_inherit(self.0, inherit)
    }
}

// --- descriptors by number, as Unix's dup2, close and fcntl ---------------------
// For a program that arranges its own descriptors, as the shell does for
// redirections and pipelines; the rest take OwnedFd and File.

/// Make descriptor `to` a copy of `fd`, closing what `to` named.
pub fn dup2(fd: i32, to: i32) -> io::Result<()> {
    sys::check(sys::call(sys::SYS_DUP2, &[fd, to])).map(|_| ())
}

/// Close descriptor `fd`; one that is not open is let be.
pub fn close(fd: i32) {
    sys::call(sys::SYS_CLOSE, &[fd]);
}

/// Whether descriptor `fd` names something: dup2 onto itself changes
/// nothing (fdflags would clear its flags), and is E_BADF if it does not.
pub fn is_open(fd: i32) -> bool {
    sys::call(sys::SYS_DUP2, &[fd, fd]) >= 0
}

/// Keep descriptor `fd` from the children this program starts
/// (FD_NOINHERIT), or let them have it again.
pub fn set_inherit(fd: i32, inherit: bool) -> io::Result<()> {
    let flags = if inherit { 0 } else { sys::FD_NOINHERIT };
    sys::check(sys::call(sys::SYS_FDFLAGS, &[fd, flags])).map(|_| ())
}

impl Drop for OwnedFd {
    fn drop(&mut self) {
        sys::call(sys::SYS_CLOSE, &[self.0]);
    }
}

/// An open file (or directory, to list).
#[derive(Debug)]
pub struct File {
    fd: OwnedFd,
}

/// How to open a file, as std's: `OpenOptions::new().append(true).open(p)`.
#[derive(Clone, Debug)]
pub struct OpenOptions {
    read: bool,
    write: bool,
    append: bool,
    truncate: bool,
    create: bool,
    create_new: bool,
}

impl Default for OpenOptions {
    fn default() -> Self {
        Self::new()
    }
}

impl OpenOptions {
    pub fn new() -> OpenOptions {
        OpenOptions {
            read: false,
            write: false,
            append: false,
            truncate: false,
            create: false,
            create_new: false,
        }
    }

    pub fn read(&mut self, on: bool) -> &mut Self {
        self.read = on;
        self
    }

    pub fn write(&mut self, on: bool) -> &mut Self {
        self.write = on;
        self
    }

    pub fn append(&mut self, on: bool) -> &mut Self {
        self.append = on;
        self
    }

    pub fn truncate(&mut self, on: bool) -> &mut Self {
        self.truncate = on;
        self
    }

    pub fn create(&mut self, on: bool) -> &mut Self {
        self.create = on;
        self
    }

    /// Create the file, failing with AlreadyExists if it is there.
    pub fn create_new(&mut self, on: bool) -> &mut Self {
        self.create_new = on;
        self
    }

    pub fn open<P: AsRef<[u8]>>(&self, path: P) -> io::Result<File> {
        let path = path.as_ref();
        let writing = self.write || self.append;
        let mut flags = match (self.read, writing) {
            (true, true) => sys::O_RDWR,
            (false, true) => sys::O_WRONLY,
            _ => sys::O_RDONLY,
        };
        if self.create_new {
            // The file server has no O_EXCL, so look first.
            if metadata(path).is_ok() {
                return Err(io::Error::from_raw(sys::E_EXIST));
            }
            flags += sys::O_CREAT;
        } else if self.create {
            flags += sys::O_CREAT;
        }
        if self.truncate {
            flags += sys::O_TRUNC;
        }
        if self.append {
            flags += sys::O_APPEND;
        }
        let path = CPath::new(path)?;
        let fd = FS.call(sys::FS_OPEN, &[path.ptr(), flags])?;
        Ok(File { fd: OwnedFd(fd) })
    }
}

impl File {
    /// Open a file to read.
    pub fn open<P: AsRef<[u8]>>(path: P) -> io::Result<File> {
        OpenOptions::new().read(true).open(path)
    }

    /// Open a file to write, made if missing and emptied if not.
    pub fn create<P: AsRef<[u8]>>(path: P) -> io::Result<File> {
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
    }

    pub fn options() -> OpenOptions {
        OpenOptions::new()
    }

    pub fn as_fd(&self) -> &OwnedFd {
        &self.fd
    }

    pub fn into_fd(self) -> OwnedFd {
        self.fd
    }

    pub fn from_fd(fd: OwnedFd) -> File {
        File { fd }
    }

    /// The next name in a directory opened with `open`, into `name`,
    /// "." and ".." included; None at the end. `read_dir` gives the
    /// same as `DirEntry`s, on the heap; this needs none.
    pub fn read_name<'a>(
        &self,
        name: &'a mut [u8; sys::NAME_MAX as usize + 1],
    ) -> io::Result<Option<&'a [u8]>> {
        if self.fd.iocall(sys::IO_READDIR, name.as_mut_ptr() as i32, 0)? == 0 {
            return Ok(None);
        }
        let len = name.iter().position(|&c| c == 0).unwrap_or(name.len());
        Ok(Some(&name[..len]))
    }
}

impl Read for File {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.fd.read(buf)
    }
}

impl Write for File {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.fd.write(buf)
    }
}

impl Read for &File {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.fd.read(buf)
    }
}

impl Write for &File {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.fd.write(buf)
    }
}

impl Seek for File {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let (offset, whence) = match pos {
            SeekFrom::Start(n) => (n as i64, sys::SEEK_SET),
            SeekFrom::Current(n) => (n, sys::SEEK_CUR),
            SeekFrom::End(n) => (n, sys::SEEK_END),
        };
        let offset = i32::try_from(offset).map_err(|_| io::Error::from_raw(sys::E_INVAL))?;
        self.fd
            .iocall(sys::IO_LSEEK, offset, whence)
            .map(|n| n as u64)
    }
}

/// What a file is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileType(i32);

impl FileType {
    pub fn is_dir(&self) -> bool {
        self.0 == sys::T_DIR
    }

    pub fn is_file(&self) -> bool {
        self.0 == sys::T_FILE
    }
}

/// What stat says of a file.
#[derive(Clone, Debug)]
pub struct Metadata {
    ino: i32,
    kind: FileType,
    links: i32,
    len: u64,
}

impl Metadata {
    pub fn file_type(&self) -> FileType {
        self.kind
    }

    pub fn is_dir(&self) -> bool {
        self.kind.is_dir()
    }

    pub fn is_file(&self) -> bool {
        self.kind.is_file()
    }

    /// Its size in bytes.
    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Its inode number.
    pub fn ino(&self) -> i32 {
        self.ino
    }

    /// How many directory entries name it.
    pub fn nlink(&self) -> i32 {
        self.links
    }
}

/// What the file at `path` is (FS_STAT).
pub fn metadata<P: AsRef<[u8]>>(path: P) -> io::Result<Metadata> {
    let path = CPath::new(path.as_ref())?;
    let words: Words<16> = Words::new();
    FS.call(sys::FS_STAT, &[path.ptr(), words.ptr() as i32])?;
    Ok(Metadata {
        ino: words.word(sys::ST_INO),
        kind: FileType(words.word(sys::ST_TYPE)),
        links: words.word(sys::ST_LINKS),
        len: words.word(sys::ST_SIZE) as u64,
    })
}

/// Whether `path` names anything.
pub fn exists<P: AsRef<[u8]>>(path: P) -> io::Result<bool> {
    match metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// The whole file.
pub fn read<P: AsRef<[u8]>>(path: P) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    File::open(path)?.read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// The whole file, as text: InvalidData if it is not UTF-8.
pub fn read_to_string<P: AsRef<[u8]>>(path: P) -> io::Result<String> {
    let mut s = String::new();
    File::open(path)?.read_to_string(&mut s)?;
    Ok(s)
}

/// Make the file hold `contents`, made if missing.
pub fn write<P: AsRef<[u8]>, C: AsRef<[u8]>>(path: P, contents: C) -> io::Result<()> {
    File::create(path)?.write_all(contents.as_ref())
}

fn path_call(op: i32, path: &[u8]) -> io::Result<()> {
    let path = CPath::new(path)?;
    FS.call(op, &[path.ptr()]).map(|_| ())
}

pub fn remove_file<P: AsRef<[u8]>>(path: P) -> io::Result<()> {
    path_call(sys::FS_UNLINK, path.as_ref())
}

pub fn create_dir<P: AsRef<[u8]>>(path: P) -> io::Result<()> {
    path_call(sys::FS_MKDIR, path.as_ref())
}

/// Remove an empty directory.
pub fn remove_dir<P: AsRef<[u8]>>(path: P) -> io::Result<()> {
    path_call(sys::FS_RMDIR, path.as_ref())
}

/// Give what `from` names the name `to`, replacing a file there.
pub fn rename<P: AsRef<[u8]>, Q: AsRef<[u8]>>(from: P, to: Q) -> io::Result<()> {
    let from = CPath::new(from.as_ref())?;
    let to = CPath::new(to.as_ref())?;
    FS.call(sys::FS_RENAME, &[from.ptr(), to.ptr()]).map(|_| ())
}

/// Copy a file's contents to another: how many bytes.
pub fn copy<P: AsRef<[u8]>, Q: AsRef<[u8]>>(from: P, to: Q) -> io::Result<u64> {
    let mut input = File::open(from)?;
    let mut output = File::create(to)?;
    io::copy(&mut input, &mut output)
}

/// The entries of a directory, "." and ".." left out.
pub fn read_dir<P: AsRef<[u8]>>(path: P) -> io::Result<ReadDir> {
    let dir = File::open(path.as_ref())?;
    let mut base = Vec::from(path.as_ref());
    if !base.is_empty() && base.last() != Some(&b'/') {
        base.push(b'/');
    }
    Ok(ReadDir { dir, base })
}

pub struct ReadDir {
    dir: File,
    base: Vec<u8>,
}

/// One entry of a directory.
#[derive(Clone, Debug)]
pub struct DirEntry {
    name: String,
    ino: i32,
    path: Vec<u8>,
}

impl DirEntry {
    pub fn file_name(&self) -> &str {
        &self.name
    }

    pub fn ino(&self) -> i32 {
        self.ino
    }

    /// The directory's path joined with the name.
    pub fn path(&self) -> &[u8] {
        &self.path
    }

    pub fn metadata(&self) -> io::Result<Metadata> {
        metadata(&self.path)
    }

    pub fn file_type(&self) -> io::Result<FileType> {
        self.metadata().map(|m| m.file_type())
    }
}

impl Iterator for ReadDir {
    type Item = io::Result<DirEntry>;

    fn next(&mut self) -> Option<io::Result<DirEntry>> {
        loop {
            let mut name = [0u8; sys::NAME_MAX as usize + 1];
            let ino = match self
                .dir
                .fd
                .iocall(sys::IO_READDIR, name.as_mut_ptr() as i32, 0)
            {
                Ok(0) => return None,
                Ok(ino) => ino,
                Err(e) => return Some(Err(e)),
            };
            let len = name.iter().position(|&c| c == 0).unwrap_or(name.len());
            let name = &name[..len];
            if name == b"." || name == b".." {
                continue;
            }
            let mut path = self.base.clone();
            path.extend_from_slice(name);
            return Some(Ok(DirEntry {
                name: String::from_utf8_lossy(name).into_owned(),
                ino,
                path,
            }));
        }
    }
}

/// How full the disk is (FS_STATFS).
#[derive(Clone, Copy, Debug)]
pub struct FsStats {
    pub blocks: i32,
    pub blocks_free: i32,
    pub inodes: i32,
    pub inodes_free: i32,
}

pub fn statfs() -> io::Result<FsStats> {
    let words: Words<{ sys::STATFS as usize + 4 }> = Words::new();
    FS.call(sys::FS_STATFS, &[words.ptr() as i32])?;
    Ok(FsStats {
        blocks: words.word(sys::SF_BLOCKS),
        blocks_free: words.word(sys::SF_BFREE),
        inodes: words.word(sys::SF_INODES),
        inodes_free: words.word(sys::SF_IFREE),
    })
}
