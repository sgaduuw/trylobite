//! The filesystem on a disk in memory, checked after every change.

use std::collections::BTreeMap;
use std::string::String;
use std::vec::Vec;

use crate::check::check;
use crate::fs::{Fs, Time};
use crate::key::NAME_LEN;
use crate::layout::*;
use crate::mem::MemStore;
use crate::tree::Item;

fn cps(s: &str) -> Vec<i32> {
    s.chars().map(|c| c as i32).collect()
}

fn new(blocks: usize) -> Fs<MemStore> {
    let mut fs = Fs::new(MemStore::new(blocks));
    fs.now = Time { secs: 1_800_000_000, nanos: 5 };
    fs.format(blocks as i64).unwrap();
    fs
}

fn ok(fs: &mut Fs<MemStore>) {
    let bad = check(fs);
    assert!(bad.is_empty(), "{bad:#?}");
}

/// Mount the disk afresh from its image, as another program would.
fn remount(fs: &Fs<MemStore>) -> Fs<MemStore> {
    let mut again = Fs::new(MemStore::from_image(&fs.store.image()));
    again.mount().unwrap();
    again
}

fn names(fs: &mut Fs<MemStore>, dir: i64) -> Vec<String> {
    let mut out = Vec::new();
    let mut it = Item::new();
    let mut after = None;
    while fs.next_entry(dir, after.as_ref(), &mut it).unwrap() {
        let mut name = [0; NAME_LEN];
        let n = it.key.name(&mut name);
        out.push(name[..n].iter().map(|&c| char::from_u32(c as u32).unwrap()).collect());
        after = Some(it.key);
    }
    out
}

#[test]
fn a_new_filesystem_is_an_empty_root() {
    let mut fs = new(10);
    ok(&mut fs);
    let root = fs.iget(ROOT_INO).unwrap();
    assert!(root.is_dir());
    assert_eq!((root.links, root.size, root.parent), (2, 2, ROOT_INO));
    assert_eq!(root.mtime, Time { secs: 1_800_000_000, nanos: 5 });
    assert_eq!(fs.free_blocks(), 10 - 2); // the superblock and the leaf
    let mut fs = remount(&fs);
    ok(&mut fs);
    assert_eq!(fs.inodes, 1);
}

#[test]
fn a_blank_disk_is_no_filesystem() {
    let mut fs = Fs::new(MemStore::new(4));
    assert_eq!(fs.mount(), Err(E_NOFS));
}

#[test]
fn a_damaged_node_is_noticed() {
    let fs = new(10);
    let mut image = fs.store.image();
    let root = fs.root as usize;
    let at = (root * PAGE as usize + 3 * N_ITEMS as usize + 5) * 2; // inside the root's item
    image[at] ^= 1;
    let mut bad = Fs::new(MemStore::from_image(&image));
    assert_eq!(bad.mount(), Err(E_IO));
}

#[test]
fn files_and_directories_come_and_go() {
    let mut fs = new(20);
    let a = fs.create(ROOT_INO, &cps("a"), T_DIR, MODE_DIR).unwrap();
    let f = fs.create(a.ino, &cps("notes"), T_FILE, MODE_FILE).unwrap();
    fs.commit().unwrap();
    ok(&mut fs);
    assert_eq!(fs.resolve(ROOT_INO, &cps("/a/notes")).unwrap(), f.ino);
    assert_eq!(fs.resolve(a.ino, &cps("../a/./notes")).unwrap(), f.ino);
    assert_eq!(fs.resolve(ROOT_INO, &cps("a/notes/x")), Err(E_NOTDIR));
    assert_eq!(fs.resolve(ROOT_INO, &cps("b")), Err(E_NOENT));
    assert_eq!(fs.resolve(ROOT_INO, &cps("")), Err(E_NOENT));
    assert_eq!(fs.iget(ROOT_INO).unwrap().links, 3);
    assert_eq!(fs.create(a.ino, &cps("notes"), T_FILE, MODE_FILE).unwrap_err(), E_EXIST);
    assert_eq!(fs.create(a.ino, &cps("a b"), T_FILE, MODE_FILE).unwrap_err(), E_INVAL);
    let long = "x".repeat(NAME_MAX as usize + 1);
    assert_eq!(fs.create(a.ino, &cps(&long), T_FILE, MODE_FILE).unwrap_err(), E_NAMETOOLONG);
    assert_eq!(fs.rmdir(ROOT_INO, &cps("a")), Err(E_NOTEMPTY));
    assert_eq!(fs.unlink(ROOT_INO, &cps("a")), Err(E_ISDIR));
    fs.unlink(a.ino, &cps("notes")).unwrap();
    fs.rmdir(ROOT_INO, &cps("a")).unwrap();
    fs.commit().unwrap();
    ok(&mut fs);
    assert_eq!(fs.inodes, 1);
    assert_eq!(fs.free_blocks(), 20 - 2);
}

#[test]
fn a_directory_lists_in_name_order() {
    let mut fs = new(20);
    for n in ["pear", "apple", "fig", "Banana", "apple2", "a"] {
        fs.create(ROOT_INO, &cps(n), T_FILE, MODE_FILE).unwrap();
    }
    fs.commit().unwrap();
    assert_eq!(names(&mut fs, ROOT_INO), ["Banana", "a", "apple", "apple2", "fig", "pear"]);
}

#[test]
fn many_files_split_the_tree_and_go_again() {
    let mut fs = new(200);
    let n = 2000;
    for i in 0..n {
        let name = std::format!("file-{i:05}-with-a-longer-name");
        fs.create(ROOT_INO, &cps(&name), T_FILE, MODE_FILE).unwrap();
        if i % 500 == 0 {
            fs.commit().unwrap();
        }
    }
    fs.commit().unwrap();
    ok(&mut fs);
    let root = fs.root;
    let s = fs.node(root).unwrap();
    assert!(crate::node::level(&fs.store, s) >= 1, "2000 files fit one leaf?");
    let mut again = remount(&fs);
    ok(&mut again);
    assert_eq!(names(&mut again, ROOT_INO).len(), n);
    for i in (0..n).rev() {
        let name = std::format!("file-{i:05}-with-a-longer-name");
        fs.unlink(ROOT_INO, &cps(&name)).unwrap();
        if i % 300 == 0 {
            fs.commit().unwrap();
            ok(&mut fs);
        }
    }
    fs.commit().unwrap();
    ok(&mut fs);
    assert_eq!(fs.free_blocks(), 200 - 2, "the tree shrank back to one leaf");
}

#[test]
fn an_aborted_call_leaves_the_disk_as_it_was() {
    let mut fs = new(20);
    fs.create(ROOT_INO, &cps("kept"), T_FILE, MODE_FILE).unwrap();
    fs.commit().unwrap();
    let image = fs.store.image();
    let free = fs.free_blocks();
    fs.create(ROOT_INO, &cps("lost"), T_DIR, MODE_DIR).unwrap();
    let f = fs.resolve(ROOT_INO, &cps("kept")).unwrap();
    fs.bmap_alloc(f, 0).unwrap();
    fs.abort();
    assert_eq!(fs.store.image(), image);
    assert_eq!(fs.free_blocks(), free);
    assert_eq!(names(&mut fs, ROOT_INO), ["kept"]);
    ok(&mut fs);
}

#[test]
fn the_old_tree_stays_on_the_disk_until_the_commit() {
    // Copy-on-write: a change never writes over a block the committed
    // tree uses, so the image as committed still mounts as it was.
    let mut fs = new(20);
    fs.create(ROOT_INO, &cps("one"), T_FILE, MODE_FILE).unwrap();
    fs.commit().unwrap();
    let before = fs.store.image();
    let old_root = fs.root;
    fs.create(ROOT_INO, &cps("two"), T_FILE, MODE_FILE).unwrap();
    assert_ne!(fs.root, old_root);
    let mut mid = fs.store.image();
    // Everything but the superblock may differ: put the old one back.
    let sb = PAGE as usize * 2;
    mid[..sb].copy_from_slice(&before[..sb]);
    let mut old = Fs::new(MemStore::from_image(&mid));
    old.mount().unwrap();
    assert_eq!(names(&mut old, ROOT_INO), ["one"]);
    ok(&mut old);
}

#[test]
fn file_blocks_grow_extents_and_holes_read_as_none() {
    let mut fs = new(40);
    let f = fs.create(ROOT_INO, &cps("data"), T_FILE, MODE_FILE).unwrap();
    for fb in 0..5 {
        let (_, new) = fs.bmap_alloc(f.ino, fb).unwrap();
        assert!(new);
    }
    let (b9, _) = fs.bmap_alloc(f.ino, 9).unwrap();
    let mut node = fs.iget(f.ino).unwrap();
    node.size = 10 * PAGE;
    fs.iput(&node).unwrap();
    fs.commit().unwrap();
    ok(&mut fs);
    let b0 = fs.bmap(f.ino, 0).unwrap();
    for fb in 0..5 {
        assert_eq!(fs.bmap(f.ino, fb).unwrap(), b0 + fb, "one extent");
    }
    assert_eq!(fs.bmap(f.ino, 7).unwrap(), NO_BLOCK);
    assert_eq!(fs.bmap(f.ino, 9).unwrap(), b9);
    assert_eq!(fs.bmap_alloc(f.ino, 2).unwrap(), (b0 + 2, false));
    let extents = crate::check::records(&mut fs).unwrap().iter().filter(|r| r.key.kind() == K_EXTENT).count();
    assert_eq!(extents, 2);
    fs.free_data(f.ino, 3).unwrap();
    let mut node = fs.iget(f.ino).unwrap();
    node.size = 3 * PAGE;
    fs.iput(&node).unwrap();
    fs.commit().unwrap();
    ok(&mut fs);
    assert_eq!(fs.bmap(f.ino, 2).unwrap(), b0 + 2);
    assert_eq!(fs.bmap(f.ino, 3).unwrap(), NO_BLOCK);
    assert_eq!(fs.bmap(f.ino, 9).unwrap(), NO_BLOCK);
    let free = fs.free_blocks();
    fs.unlink(ROOT_INO, &cps("data")).unwrap();
    fs.commit().unwrap();
    assert_eq!(fs.free_blocks(), free + 3);
    ok(&mut fs);
}

#[test]
fn a_full_disk_says_so_and_changes_nothing() {
    let mut fs = new(6);
    let f = fs.create(ROOT_INO, &cps("big"), T_FILE, MODE_FILE).unwrap();
    fs.commit().unwrap();
    let mut fb = 0;
    loop {
        match fs.bmap_alloc(f.ino, fb) {
            Ok(_) => {
                let mut node = fs.iget(f.ino).unwrap();
                node.size = (fb + 1) * PAGE;
                match fs.iput(&node) {
                    Ok(()) => {}
                    Err(e) => {
                        assert_eq!(e, E_NOSPC);
                        fs.abort();
                        break;
                    }
                }
                match fs.commit() {
                    Ok(()) => fb += 1,
                    Err(e) => panic!("{e}"),
                }
            }
            Err(e) => {
                assert_eq!(e, E_NOSPC);
                fs.abort();
                break;
            }
        }
    }
    ok(&mut fs);
    assert!(fb >= 1);
    let mut again = remount(&fs);
    ok(&mut again);
}

#[test]
fn rename_moves_and_replaces() {
    let mut fs = new(30);
    let a = fs.create(ROOT_INO, &cps("a"), T_DIR, MODE_DIR).unwrap();
    let b = fs.create(ROOT_INO, &cps("b"), T_DIR, MODE_DIR).unwrap();
    let x = fs.create(a.ino, &cps("x"), T_FILE, MODE_FILE).unwrap();
    let y = fs.create(b.ino, &cps("y"), T_FILE, MODE_FILE).unwrap();
    fs.rename(a.ino, &cps("x"), b.ino, &cps("y")).unwrap(); // replaces y
    ok(&mut fs);
    assert_eq!(fs.resolve(ROOT_INO, &cps("b/y")).unwrap(), x.ino);
    assert!(fs.iget(y.ino).is_err());
    assert_eq!(fs.rename(ROOT_INO, &cps("a"), a.ino, &cps("in")), Err(E_INVAL));
    assert_eq!(fs.rename(ROOT_INO, &cps("a"), ROOT_INO, &cps("b")), Err(E_EXIST));
    let f = fs.create(ROOT_INO, &cps("f"), T_FILE, MODE_FILE).unwrap();
    assert_eq!(fs.rename(ROOT_INO, &cps("f"), ROOT_INO, &cps("b")), Err(E_ISDIR));
    fs.rename(ROOT_INO, &cps("a"), b.ino, &cps("a2")).unwrap(); // a directory moves
    ok(&mut fs);
    assert_eq!(fs.iget(a.ino).unwrap().parent, b.ino);
    assert_eq!(fs.resolve(a.ino, &cps("../y")).unwrap(), x.ino);
    fs.rename(ROOT_INO, &cps("f"), ROOT_INO, &cps("g")).unwrap();
    assert_eq!(fs.resolve(ROOT_INO, &cps("g")).unwrap(), f.ino);
    fs.commit().unwrap();
    ok(&mut fs);
    let mut name = [0; NAME_LEN];
    let n = fs.name_in_parent(a.ino, &mut name).unwrap();
    assert_eq!(&name[..n], &cps("a2")[..]);
}

#[test]
fn a_mixed_workload_against_a_model() {
    // Files made, grown and removed in a pseudo-random order, with the
    // tree checked against a plain map of what should be there.
    let mut fs = new(400);
    let mut model: BTreeMap<String, i64> = BTreeMap::new();
    let mut committed = model.clone();
    let mut seed: u64 = 12345;
    let mut rand = |n: u64| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (seed >> 33) % n
    };
    for step in 0..3000 {
        let name = std::format!("n{}", rand(400));
        match rand(4) {
            0 | 1 => match fs.create(ROOT_INO, &cps(&name), T_FILE, MODE_FILE) {
                Ok(node) => {
                    assert!(!model.contains_key(&name));
                    model.insert(name, node.ino);
                }
                Err(e) => assert!(e == E_EXIST && model.contains_key(&name), "{e}"),
            },
            2 => match fs.unlink(ROOT_INO, &cps(&name)) {
                Ok(()) => assert!(model.remove(&name).is_some()),
                Err(e) => assert!(e == E_NOENT && !model.contains_key(&name)),
            },
            _ => {
                if let Some(&ino) = model.get(&name) {
                    let fb = rand(3) as i64;
                    fs.bmap_alloc(ino, fb).unwrap();
                    let mut node = fs.iget(ino).unwrap();
                    node.size = node.size.max((fb + 1) * PAGE);
                    fs.iput(&node).unwrap();
                }
            }
        }
        if rand(5) == 0 {
            fs.abort();
            model = committed.clone();
        } else {
            fs.commit().unwrap();
            committed = model.clone();
        }
        if step % 500 == 0 {
            ok(&mut fs);
            let mut again = remount(&fs);
            ok(&mut again);
            assert_eq!(names(&mut again, ROOT_INO), model.keys().cloned().collect::<Vec<_>>());
        }
    }
    fs.commit().unwrap();
    ok(&mut fs);
    let listed = names(&mut fs, ROOT_INO);
    assert_eq!(listed, model.keys().cloned().collect::<Vec<_>>());
}
