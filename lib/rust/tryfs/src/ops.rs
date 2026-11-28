//! Inodes, directories, paths and files, on the tree.
//!
//! Each operation changes the tree within the caller's transaction: the
//! caller commits once the whole call has worked, or aborts.
//!
//! A directory's entries are its items [dir, K_DIRENT, name...], in name
//! order; `.` and `..` are not stored, but answered from the directory
//! itself and its IN_PARENT. A directory's size is its entry count, `.`
//! and `..` included, and its links are 2 and one for each
//! subdirectory's `..`. A file's data is its extents, [ino, K_EXTENT,
//! end] = [first block, length]: file blocks end - length to end - 1,
//! in disk blocks first to first + length - 1. A file block no extent
//! covers is a hole, and reads as zeros.

use crate::fs::{Fs, Inode, Time};
use crate::key::{Key, NAME_LEN};
use crate::layout::*;
use crate::store::Store;
use crate::tree::Item;
use crate::Result;

const DOT: i32 = '.' as i32;
const SLASH: i32 = '/' as i32;

/// Whether `name` is `.` or `..`.
pub fn is_dots(name: &[i32]) -> bool {
    matches!(name, [DOT] | [DOT, DOT])
}

/// Whether `name` may be a new entry's: 1 to NAME_MAX code points, none
/// a space, a slash or a control character, and not `.` or `..`.
pub fn name_ok(name: &[i32]) -> Result<()> {
    if name.len() > NAME_LEN {
        return Err(E_NAMETOOLONG);
    }
    if name.is_empty() || is_dots(name) || name.iter().any(|&c| c <= ' ' as i32 || c == SLASH || c == 127) {
        return Err(E_INVAL);
    }
    Ok(())
}

/// Where a path's last name is, after the rest has been followed.
pub struct Last {
    /// The directory it is in.
    pub dir: i64,
    /// Its first code point's index in the path, and one past its last;
    /// equal for a path with no last name (the root, or empty).
    pub start: usize,
    pub end: usize,
}

impl<S: Store> Fs<S> {
    /// Inode `ino`'s record: E_IO if there is none.
    pub fn iget(&mut self, ino: i64) -> Result<Inode> {
        for node in self.icache.iter().flatten() {
            if node.ino == ino {
                return Ok(*node);
            }
        }
        let mut it = Item::new();
        if !self.get(&Key::inode(ino), &mut it)? || it.len != INODE_WORDS as usize {
            return Err(E_IO);
        }
        let node = Inode::from_words(ino, it.value());
        self.cache_inode(&node);
        Ok(node)
    }

    /// Store an inode's record.
    pub fn iput(&mut self, node: &Inode) -> Result<()> {
        self.put(&Key::inode(node.ino), &node.to_words())?;
        self.cache_inode(node);
        Ok(())
    }

    /// A new inode, stored: a directory with `parent` as its parent and
    /// 2 links, or a file with 1; its times all now.
    pub fn new_inode(&mut self, typ: i64, mode: i64, parent: i64) -> Result<Inode> {
        let ino = self.next_ino;
        let dir = typ == T_DIR;
        let node = Inode {
            ino,
            typ,
            mode,
            uid: 0,
            gid: 0,
            links: if dir { 2 } else { 1 },
            size: if dir { 2 } else { 0 },
            atime: self.now,
            mtime: self.now,
            ctime: self.now,
            btime: self.now,
            parent: if dir { parent } else { NO_INO },
        };
        self.iput(&node)?;
        self.next_ino += 1;
        self.inodes += 1;
        Ok(node)
    }

    /// What `name` names in directory `dir`: its inode, or None.
    pub fn lookup(&mut self, dir: &Inode, name: &[i32]) -> Result<Option<i64>> {
        if !dir.is_dir() {
            return Err(E_NOTDIR);
        }
        match name {
            [DOT] => return Ok(Some(dir.ino)),
            [DOT, DOT] => return Ok(Some(dir.parent)),
            _ => {}
        }
        if name.len() > NAME_LEN {
            return Err(E_NAMETOOLONG);
        }
        let mut it = Item::new();
        if self.get(&Key::dirent(dir.ino, name), &mut it)? {
            Ok(Some(it.value[DE_INO as usize]))
        } else {
            Ok(None)
        }
    }

    /// Follow `path` from `cwd` (or the root, for a path starting with a
    /// slash) up to its last name. E_NOENT for an empty path or a name
    /// not there on the way, E_NOTDIR for one that is not a directory,
    /// E_NAMETOOLONG for one too long.
    pub fn walk_path(&mut self, cwd: i64, path: &[i32]) -> Result<Last> {
        if path.is_empty() {
            return Err(E_NOENT);
        }
        let mut dir = if path[0] == SLASH { ROOT_INO } else { cwd };
        let mut i = 0;
        loop {
            while i < path.len() && path[i] == SLASH {
                i += 1;
            }
            let start = i;
            while i < path.len() && path[i] != SLASH {
                i += 1;
            }
            let end = i;
            while i < path.len() && path[i] == SLASH {
                i += 1;
            }
            if i == path.len() {
                return Ok(Last { dir, start, end });
            }
            let here = self.iget(dir)?;
            match self.lookup(&here, &path[start..end])? {
                Some(next) => dir = next,
                None => return Err(E_NOENT),
            }
            if !self.iget(dir)?.is_dir() {
                return Err(E_NOTDIR);
            }
        }
    }

    /// What `path` names, from `cwd`: its inode. E_NOENT if it is not
    /// there, and the failures of [`Fs::walk_path`].
    pub fn resolve(&mut self, cwd: i64, path: &[i32]) -> Result<i64> {
        let last = self.walk_path(cwd, path)?;
        if last.start == last.end {
            return Ok(last.dir); // the root, or a path of slashes
        }
        let dir = self.iget(last.dir)?;
        self.lookup(&dir, &path[last.start..last.end])?.ok_or(E_NOENT)
    }

    /// Make `name` in directory `dir` a new file or directory (`typ`),
    /// with permissions `mode`: E_EXIST if the name is taken, E_INVAL or
    /// E_NAMETOOLONG for a name that may not be one, E_NOSPC.
    pub fn create(&mut self, dir: i64, name: &[i32], typ: i64, mode: i64) -> Result<Inode> {
        let mut parent = self.iget(dir)?;
        if !parent.is_dir() {
            return Err(E_NOTDIR);
        }
        if self.lookup(&parent, name)?.is_some() {
            return Err(E_EXIST);
        }
        name_ok(name)?;
        let node = self.new_inode(typ, mode, dir)?;
        self.link(&mut parent, name, &node)?;
        if node.is_dir() {
            parent.links += 1; // its ..
        }
        self.iput(&parent)?;
        Ok(node)
    }

    /// Enter `node` in directory `parent` as `name`; the caller stores
    /// the directory's record.
    fn link(&mut self, parent: &mut Inode, name: &[i32], node: &Inode) -> Result<()> {
        self.put(&Key::dirent(parent.ino, name), &[node.ino, node.typ])?;
        parent.size += 1;
        parent.mtime = self.now;
        parent.ctime = self.now;
        Ok(())
    }

    /// Take `name` out of directory `parent`; the caller stores the
    /// directory's record.
    fn unlink_entry(&mut self, parent: &mut Inode, name: &[i32]) -> Result<()> {
        if !self.delete(&Key::dirent(parent.ino, name))? {
            return Err(E_NOENT);
        }
        parent.size -= 1;
        parent.mtime = self.now;
        parent.ctime = self.now;
        Ok(())
    }

    /// One name of `node` fewer: when it has none left, it goes, and its
    /// blocks with it.
    fn drop_link(&mut self, mut node: Inode) -> Result<()> {
        node.links -= 1;
        if node.links > 0 && !node.is_dir() {
            node.ctime = self.now;
            return self.iput(&node);
        }
        self.free_data(node.ino, 0)?;
        self.delete(&Key::inode(node.ino))?;
        self.inodes -= 1;
        Ok(())
    }

    /// Remove file `name` from directory `dir`: E_NOENT, E_ISDIR, E_INVAL
    /// for `.` or `..`.
    pub fn unlink(&mut self, dir: i64, name: &[i32]) -> Result<()> {
        let mut parent = self.iget(dir)?;
        if is_dots(name) {
            return Err(E_INVAL);
        }
        let ino = self.lookup(&parent, name)?.ok_or(E_NOENT)?;
        let node = self.iget(ino)?;
        if node.is_dir() {
            return Err(E_ISDIR);
        }
        self.unlink_entry(&mut parent, name)?;
        self.iput(&parent)?;
        self.drop_link(node)
    }

    /// Whether directory `dir` holds nothing but `.` and `..`.
    pub fn dir_empty(&mut self, dir: i64) -> Result<bool> {
        let mut it = Item::new();
        let found = self.seek(&Key::dirent(dir, &[]), false, &mut it)?;
        Ok(!(found && it.key.ino() == dir && it.key.kind() == K_DIRENT))
    }

    /// Remove empty directory `name` from directory `dir`: E_NOENT,
    /// E_NOTDIR, E_NOTEMPTY, E_INVAL for `.` or `..`.
    pub fn rmdir(&mut self, dir: i64, name: &[i32]) -> Result<()> {
        let mut parent = self.iget(dir)?;
        if is_dots(name) {
            return Err(E_INVAL);
        }
        let ino = self.lookup(&parent, name)?.ok_or(E_NOENT)?;
        let node = self.iget(ino)?;
        if !node.is_dir() {
            return Err(E_NOTDIR);
        }
        if !self.dir_empty(ino)? {
            return Err(E_NOTEMPTY);
        }
        self.unlink_entry(&mut parent, name)?;
        parent.links -= 1; // its ..
        self.iput(&parent)?;
        self.delete(&Key::inode(ino))?;
        self.inodes -= 1;
        Ok(())
    }

    /// Whether directory `dir` is `ancestor` or inside it.
    fn within(&mut self, mut dir: i64, ancestor: i64) -> Result<bool> {
        for _ in 0..self.inodes + 1 {
            if dir == ancestor {
                return Ok(true);
            }
            if dir == ROOT_INO {
                return Ok(false);
            }
            dir = self.iget(dir)?.parent;
        }
        Err(E_IO) // a loop of parents
    }

    /// Give what `from` names in directory `fdir` the name `to` in
    /// directory `tdir`, replacing a file of that name. E_NOENT, E_ISDIR
    /// (to is a directory), E_EXIST (from is a directory and to exists),
    /// E_INVAL (. or .., or a directory into itself), and the failures of
    /// [`Fs::create`] for the new name.
    pub fn rename(&mut self, fdir: i64, from: &[i32], tdir: i64, to: &[i32]) -> Result<()> {
        if is_dots(from) || is_dots(to) {
            return Err(E_INVAL);
        }
        let mut src = self.iget(fdir)?;
        let ino = self.lookup(&src, from)?.ok_or(E_NOENT)?;
        let mut node = self.iget(ino)?;
        let dst = self.iget(tdir)?;
        if !dst.is_dir() {
            return Err(E_NOTDIR);
        }
        let old = self.lookup(&dst, to)?;
        if old == Some(ino) {
            return Ok(()); // the same file: nothing to do
        }
        if let Some(old) = old {
            if node.is_dir() {
                return Err(E_EXIST);
            }
            if self.iget(old)?.is_dir() {
                return Err(E_ISDIR);
            }
        }
        name_ok(to)?;
        if node.is_dir() && self.within(tdir, ino)? {
            return Err(E_INVAL);
        }
        // Out of the old directory.
        self.unlink_entry(&mut src, from)?;
        if node.is_dir() && fdir != tdir {
            src.links -= 1;
        }
        self.iput(&src)?;
        // A file it replaces loses that name.
        let mut dst = self.iget(tdir)?;
        if let Some(old) = old {
            self.unlink_entry(&mut dst, to)?;
            let gone = self.iget(old)?;
            self.drop_link(gone)?;
        }
        // Into the new one.
        self.link(&mut dst, to, &node)?;
        if node.is_dir() && fdir != tdir {
            dst.links += 1;
            node.parent = tdir;
        }
        self.iput(&dst)?;
        node.ctime = self.now;
        self.iput(&node)
    }

    /// The name directory `dir` has in its parent, into `out`: how many
    /// code points. The root has none.
    pub fn name_in_parent(&mut self, dir: i64, out: &mut [i32; NAME_LEN]) -> Result<usize> {
        let node = self.iget(dir)?;
        if dir == ROOT_INO {
            return Ok(0);
        }
        let mut it = Item::new();
        let mut k = Key::dirent(node.parent, &[]);
        let mut strict = false;
        while self.seek(&k, strict, &mut it)? {
            if it.key.ino() != node.parent || it.key.kind() != K_DIRENT {
                break;
            }
            if it.value[DE_INO as usize] == dir {
                return Ok(it.key.name(out));
            }
            k = it.key;
            strict = true;
        }
        Err(E_IO) // a directory its parent does not list
    }

    /// The entry of directory `dir` after `after` (from the first with
    /// None), `.` and `..` not counted: its key and inode, or None at the
    /// end.
    pub fn next_entry(&mut self, dir: i64, after: Option<&Key>, it: &mut Item) -> Result<bool> {
        let found = match after {
            Some(k) => self.seek(k, true, it)?,
            None => self.seek(&Key::dirent(dir, &[]), false, it)?,
        };
        Ok(found && it.key.ino() == dir && it.key.kind() == K_DIRENT)
    }

    /// The disk block holding file block `fb` of inode `ino`, or NO_BLOCK
    /// for a hole.
    pub fn bmap(&mut self, ino: i64, fb: i64) -> Result<i64> {
        for &(i, first, len, start) in self.ecache.iter().flatten() {
            if i == ino && first <= fb && fb < first + len {
                return Ok(start + fb - first);
            }
        }
        let mut it = Item::new();
        if !self.seek(&Key::extent(ino, fb), true, &mut it)? {
            return Ok(NO_BLOCK);
        }
        let k = it.key;
        if k.ino() != ino || k.kind() != K_EXTENT {
            return Ok(NO_BLOCK);
        }
        let end = k.w[2];
        let first = end - it.value[EX_LEN as usize];
        if fb < first {
            return Ok(NO_BLOCK);
        }
        let start = it.value[EX_START as usize];
        self.cache_extent((ino, first, end - first, start));
        Ok(start + fb - first)
    }

    /// The disk block holding file block `fb` of inode `ino`, allocating a
    /// zeroed one for a hole, next to the block before it if that is free
    /// (which grows its extent), else near it: the block, and whether it
    /// is new. E_NOSPC, E_FBIG past the largest file.
    pub fn bmap_alloc(&mut self, ino: i64, fb: i64) -> Result<(i64, bool)> {
        if !(0..FS_MAX_BLOCKS).contains(&fb) {
            return Err(E_FBIG);
        }
        let b = self.bmap(ino, fb)?;
        if b != NO_BLOCK {
            return Ok((b, false));
        }
        let mut it = Item::new();
        let before = Key::extent(ino, fb);
        if fb > 0 && self.get(&before, &mut it)? {
            // An extent ends right here: grow it if the next disk block
            // is free.
            let start = it.value[EX_START as usize];
            let len = it.value[EX_LEN as usize];
            if self.alloc_at(start + len) {
                self.delete(&before)?;
                self.put(&Key::extent(ino, fb + 1), &[start, len + 1])?;
                self.store.zero(start + len)?;
                return Ok((start + len, true));
            }
            let b = self.alloc(start + len)?;
            return self.new_extent(ino, fb, b);
        }
        let b = self.alloc(0)?;
        self.new_extent(ino, fb, b)
    }

    fn new_extent(&mut self, ino: i64, fb: i64, b: i64) -> Result<(i64, bool)> {
        self.put(&Key::extent(ino, fb + 1), &[b, 1])?;
        self.store.zero(b)?;
        Ok((b, true))
    }

    /// Give back inode `ino`'s data blocks from file block `from` on.
    pub fn free_data(&mut self, ino: i64, from: i64) -> Result<()> {
        let mut it = Item::new();
        loop {
            if !self.seek(&Key::extent(ino, from), true, &mut it)? {
                return Ok(());
            }
            let k = it.key;
            if k.ino() != ino || k.kind() != K_EXTENT {
                return Ok(());
            }
            let end = k.w[2];
            let start = it.value[EX_START as usize];
            let len = it.value[EX_LEN as usize];
            let first = end - len;
            self.delete(&k)?;
            let keep = (from - first).max(0); // blocks of it below from
            for b in start + keep..start + len {
                self.release(b);
            }
            if keep > 0 {
                self.put(&Key::extent(ino, first + keep), &[start, keep])?;
            }
        }
    }

    /// Empty file `ino`: its blocks go, its size is 0.
    pub fn truncate(&mut self, ino: i64) -> Result<()> {
        self.free_data(ino, 0)?;
        let mut node = self.iget(ino)?;
        node.size = 0;
        node.mtime = self.now;
        node.ctime = self.now;
        self.iput(&node)
    }

    /// Note that inode `ino` was read, if that is news: its access time
    /// moves only while it is no later than its last change, as Linux's
    /// relatime has it, so reading a file does not write the disk every
    /// time.
    pub fn accessed(&mut self, ino: i64) -> Result<()> {
        if !self.atime_due(ino)? {
            return Ok(());
        }
        let mut node = self.iget(ino)?;
        node.atime = self.now;
        self.iput(&node)
    }

    /// Whether a read should bring the access time up: whether it is no
    /// later than the modification or change time.
    pub fn atime_due(&mut self, ino: i64) -> Result<bool> {
        let node = self.iget(ino)?;
        let later = |a: Time, b: Time| (a.secs, a.nanos) > (b.secs, b.nanos);
        Ok(!(later(node.atime, node.mtime) && later(node.atime, node.ctime)))
    }
}
