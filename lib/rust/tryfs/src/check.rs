//! The checker (fsck): everything a filesystem must be, checked from a
//! mounted one. Mounting has already checked each node's sum and level
//! and that no block is used twice; this checks the keys' order and the
//! records' meaning: entries name inodes that are there, links and
//! sizes add up, extents stay within their files, every inode is
//! reachable from the root, and the superblock's counts are right.

use std::collections::{BTreeMap, BTreeSet};
use std::format;
use std::string::String;
use std::vec::Vec;

use crate::fs::{Fs, Inode};
use crate::key::{self, Key, NAME_LEN};
use crate::layout::*;
use crate::node;
use crate::ops::name_ok;
use crate::store::Store;

/// One leaf item: its key and value.
pub struct Record {
    pub key: Key,
    pub value: Vec<i64>,
}

/// Every leaf item in key order, checking the tree's shape on the way:
/// keys rise within each node and stay within what their parent says.
pub fn records<S: Store>(fs: &mut Fs<S>) -> Result<Vec<Record>, String> {
    let mut out = Vec::new();
    let root = fs.root;
    collect(fs, root, None, None, &mut out)?;
    Ok(out)
}

fn collect<S: Store>(
    fs: &mut Fs<S>,
    b: i64,
    lo: Option<&Key>,
    hi: Option<&Key>,
    out: &mut Vec<Record>,
) -> Result<(), String> {
    let s = fs.node(b).map_err(|e| format!("node {b}: unreadable ({e})"))?;
    let level = node::level(&fs.store, s);
    let n = node::count(&fs.store, s);
    if level > 0 && n == 0 {
        return Err(format!("node {b}: an inner node with no children"));
    }
    let mut items = Vec::new();
    let mut pos = node::ITEMS;
    for _ in 0..n {
        let k = node::key(&fs.store, s, pos);
        let v: Vec<i64> = (0..node::vlen(&fs.store, s, pos)).map(|i| node::value(&fs.store, s, pos, i)).collect();
        items.push((k, v));
        pos += node::size(&fs.store, s, pos);
    }
    for w in items.windows(2) {
        if key::cmp(w[0].0.words(), w[1].0.words()).is_ge() {
            return Err(format!("node {b}: keys out of order"));
        }
    }
    for (i, (k, v)) in items.iter().enumerate() {
        // An inner node's first key bounds nothing: its child covers
        // every key below the second's.
        let bound = level == 0 || i > 0;
        if bound && lo.is_some_and(|lo| key::cmp(k.words(), lo.words()).is_lt()) {
            return Err(format!("node {b}: a key below its parent's"));
        }
        if hi.is_some_and(|hi| key::cmp(k.words(), hi.words()).is_ge()) {
            return Err(format!("node {b}: a key past its parent's next"));
        }
        if level == 0 {
            out.push(Record { key: *k, value: v.clone() });
        } else {
            if v.len() != 1 {
                return Err(format!("node {b}: a child that is not one block"));
            }
            let lo = if i > 0 { Some(k) } else { lo };
            let next = items.get(i + 1).map(|(k, _)| k).or(hi);
            collect(fs, v[0], lo, next, out)?;
        }
    }
    Ok(())
}

/// Check the whole filesystem: a list of what is wrong, empty if
/// nothing is.
pub fn check<S: Store>(fs: &mut Fs<S>) -> Vec<String> {
    let mut bad = Vec::new();
    let all = match records(fs) {
        Ok(all) => all,
        Err(e) => return std::vec![e],
    };
    let mut inodes: BTreeMap<i64, Inode> = BTreeMap::new();
    let mut entries: Vec<(i64, Vec<i32>, i64, i64)> = Vec::new(); // dir, name, ino, type
    let mut extents: BTreeMap<i64, Vec<(i64, i64, i64)>> = BTreeMap::new(); // ino: end, start, len
    for r in &all {
        let (ino, kind) = (r.key.ino(), r.key.kind());
        match kind {
            K_INODE if r.key.len == 2 && r.value.len() == INODE_WORDS as usize => {
                inodes.insert(ino, Inode::from_words(ino, &r.value));
            }
            K_DIRENT if r.value.len() == DIRENT_WORDS as usize => {
                let mut name = [0; NAME_LEN];
                let n = r.key.name(&mut name);
                if Key::dirent(ino, &name[..n]) != r.key {
                    bad.push(format!("directory {ino}: an entry's name is not packed as names are"));
                }
                entries.push((ino, name[..n].to_vec(), r.value[DE_INO as usize], r.value[DE_TYPE as usize]));
            }
            K_EXTENT if r.key.len == 3 && r.value.len() == EXTENT_WORDS as usize => {
                extents.entry(ino).or_default().push((r.key.w[2], r.value[0], r.value[1]));
            }
            _ => bad.push(format!("inode {ino}: a record of kind {kind} that makes no sense")),
        }
    }

    // Inodes.
    for node in inodes.values() {
        let ino = node.ino;
        if ino < ROOT_INO || ino >= fs.next_ino {
            bad.push(format!("inode {ino}: a number never handed out"));
        }
        if node.typ != T_FILE && node.typ != T_DIR {
            bad.push(format!("inode {ino}: type {}", node.typ));
        }
        if !(0..=MODE_MAX).contains(&node.mode) {
            bad.push(format!("inode {ino}: permissions {}", node.mode));
        }
        if node.size < 0 || node.links < 1 {
            bad.push(format!("inode {ino}: size {} and {} links", node.size, node.links));
        }
        for t in [node.atime, node.mtime, node.ctime, node.btime] {
            if !(0..1_000_000_000).contains(&t.nanos) {
                bad.push(format!("inode {ino}: a time of {} nanoseconds", t.nanos));
            }
        }
    }
    if fs.inodes != inodes.len() as i64 {
        bad.push(format!("the superblock counts {} inodes, the tree holds {}", fs.inodes, inodes.len()));
    }
    match inodes.get(&ROOT_INO) {
        Some(root) if root.is_dir() && root.parent == ROOT_INO => {}
        _ => bad.push(String::from("the root is not a directory that is its own parent")),
    }

    // Entries.
    let mut names: BTreeMap<i64, Vec<i64>> = BTreeMap::new(); // ino: directories naming it
    let mut counts: BTreeMap<i64, i64> = BTreeMap::new(); // dir: entries
    let mut subdirs: BTreeMap<i64, i64> = BTreeMap::new();
    for (dir, name, ino, typ) in &entries {
        let shown = String::from_iter(name.iter().filter_map(|&c| char::from_u32(c as u32)));
        match inodes.get(dir) {
            Some(d) if d.is_dir() => {}
            _ => bad.push(format!("an entry {shown:?} in {dir}, which is no directory")),
        }
        if name_ok(name).is_err() {
            bad.push(format!("directory {dir}: an entry named {shown:?}"));
        }
        match inodes.get(ino) {
            None => bad.push(format!("directory {dir}: {shown:?} names inode {ino}, which is not there")),
            Some(n) if n.typ != *typ => bad.push(format!("directory {dir}: {shown:?} has the wrong type")),
            Some(n) => {
                if n.is_dir() {
                    *subdirs.entry(*dir).or_default() += 1;
                    if n.parent != *dir {
                        bad.push(format!("directory {ino}: its parent is {}, but {dir} lists it", n.parent));
                    }
                }
            }
        }
        names.entry(*ino).or_default().push(*dir);
        *counts.entry(*dir).or_default() += 1;
    }
    for node in inodes.values() {
        let ino = node.ino;
        let named = names.get(&ino).map_or(0, |v| v.len() as i64);
        if node.is_dir() {
            if ino != ROOT_INO && named != 1 {
                bad.push(format!("directory {ino}: named {named} times"));
            }
            if ino == ROOT_INO && named != 0 {
                bad.push(String::from("the root has a name"));
            }
            let want = 2 + subdirs.get(&ino).copied().unwrap_or(0);
            if node.links != want {
                bad.push(format!("directory {ino}: {} links, should be {want}", node.links));
            }
            let want = 2 + counts.get(&ino).copied().unwrap_or(0);
            if node.size != want {
                bad.push(format!("directory {ino}: size {}, should be {want}", node.size));
            }
            if extents.contains_key(&ino) {
                bad.push(format!("directory {ino}: has data blocks"));
            }
        } else if node.links != named {
            bad.push(format!("file {ino}: {} links, named {named} times", node.links));
        }
    }
    // Reachable from the root, going down.
    let mut seen = BTreeSet::from([ROOT_INO]);
    let mut todo = std::vec![ROOT_INO];
    while let Some(dir) = todo.pop() {
        for (d, _, ino, _) in &entries {
            if *d == dir && seen.insert(*ino) && inodes.get(ino).is_some_and(Inode::is_dir) {
                todo.push(*ino);
            }
        }
    }
    for ino in inodes.keys() {
        if !seen.contains(ino) {
            bad.push(format!("inode {ino}: not reachable from the root"));
        }
    }

    // Extents.
    for (ino, list) in &extents {
        let Some(node) = inodes.get(ino) else {
            bad.push(format!("extents of inode {ino}, which is not there"));
            continue;
        };
        let blocks = (node.size + PAGE - 1) / PAGE;
        let mut prev_end = 0;
        for &(end, start, len) in list {
            if len < 1 || end - len < prev_end {
                bad.push(format!("file {ino}: extents overlap"));
            }
            if end > blocks {
                bad.push(format!("file {ino}: a block past its size"));
            }
            if start < 1 || start + len > fs.blocks {
                bad.push(format!("file {ino}: blocks outside the disk"));
            }
            prev_end = end;
        }
    }
    bad
}
