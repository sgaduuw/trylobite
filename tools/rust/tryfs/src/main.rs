//! tryfs: make and change trylobite filesystem images on the host, with
//! lib/rust/tryfs, the code the file server runs (docs/filesystem.md).
//! tools/fs.py drives it; tests and `make` reach it through that.
//!
//!     tryfs new IMAGE BLOCKS [DISK_BLOCKS]   a new, empty filesystem
//!     tryfs mkdir IMAGE PATH                 a directory
//!     tryfs put IMAGE PATH FILE              a file holding FILE's trytes
//!     tryfs get IMAGE PATH FILE              a file's trytes, to FILE (- for stdout)
//!     tryfs rm IMAGE PATH                    remove a file
//!     tryfs rmdir IMAGE PATH                 remove an empty directory
//!     tryfs mv IMAGE FROM TO                 rename
//!     tryfs chmod IMAGE PATH MODE            permissions, in decimal
//!     tryfs chown IMAGE PATH UID GID
//!     tryfs utimes IMAGE PATH ATIME MTIME    access and modification times, in seconds
//!     tryfs ls IMAGE PATH                    a directory's entries, one JSON object a line
//!     tryfs stat IMAGE PATH                  what PATH names, as JSON, with
//!                                            "data": each file block's disk block
//!     tryfs istat IMAGE INO                  the same for an inode, by number
//!     tryfs info IMAGE                       the superblock and the free blocks, as JSON
//!     tryfs check IMAGE                      check it all (fsck): what is wrong, exit 1
//!     tryfs boot IMAGE FILE PAGE ENTRY       FILE's trytes as the boot record's blocks
//!     tryfs noboot IMAGE                     no boot record
//!     tryfs batch IMAGE                      the commands on standard input, a line
//!                                            each, fields split by tabs, the image left out
//!
//! FILEs of trytes are as disk images are: each tryte a little-endian
//! i16. Paths start at the root. Times are now, or TRYFS_TIME's seconds
//! if it is set, so that a build can be repeated exactly.

use std::io::{self, BufRead, Read, Write};
use std::process::ExitCode;

use tryfs::check;
use tryfs::key::NAME_LEN;
use tryfs::layout::*;
use tryfs::mem::MemStore;
use tryfs::tree::Item;
use tryfs::{Fs, Inode, Store, Time};

type Disk = Fs<MemStore>;

/// What an E_ number is called.
fn error_name(e: i64) -> String {
    let names = [
        (E_NOFS, "no filesystem"),
        (E_NOENT, "no such file or directory"),
        (E_NOTDIR, "not a directory"),
        (E_ISDIR, "is a directory"),
        (E_INVAL, "invalid"),
        (E_NAMETOOLONG, "name too long"),
        (E_IO, "damaged"),
        (E_EXIST, "exists"),
        (E_NOSPC, "no space left"),
        (E_NOTEMPTY, "directory not empty"),
        (E_FBIG, "file too large"),
        (E_BUSY, "busy"),
    ];
    match names.iter().find(|(n, _)| *n == e) {
        Some((_, name)) => format!("{name} ({e})"),
        None => format!("error {e}"),
    }
}

fn cps(s: &str) -> Vec<i32> {
    s.chars().map(|c| c as i32).collect()
}

fn text(cps: &[i32]) -> String {
    cps.iter().map(|&c| char::from_u32(c as u32).unwrap_or('\u{fffd}')).collect()
}

fn now() -> Time {
    if let Some(secs) = std::env::var("TRYFS_TIME").ok().and_then(|s| s.parse().ok()) {
        return Time { secs, nanos: 0 };
    }
    let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    Time { secs: d.as_secs() as i64, nanos: d.subsec_nanos() as i64 }
}

fn read_trytes(file: &str) -> Result<Vec<i64>, String> {
    let data = if file == "-" {
        let mut v = Vec::new();
        io::stdin().read_to_end(&mut v).map_err(|e| e.to_string())?;
        v
    } else {
        std::fs::read(file).map_err(|e| format!("{file}: {e}"))?
    };
    Ok(data.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]]) as i64).collect())
}

fn write_trytes(file: &str, trytes: &[i64]) -> Result<(), String> {
    let data: Vec<u8> = trytes.iter().flat_map(|&t| (t as i16).to_le_bytes()).collect();
    if file == "-" {
        io::stdout().write_all(&data).map_err(|e| e.to_string())
    } else {
        std::fs::write(file, data).map_err(|e| format!("{file}: {e}"))
    }
}

fn load(image: &str) -> Result<Disk, String> {
    let data = std::fs::read(image).map_err(|e| format!("{image}: {e}"))?;
    let mut fs = Fs::new(MemStore::from_image(&data));
    fs.mount().map_err(|e| format!("{image}: {}", error_name(e)))?;
    fs.now = now();
    Ok(fs)
}

fn save(fs: &Disk, image: &str) -> Result<(), String> {
    std::fs::write(image, fs.store.image()).map_err(|e| format!("{image}: {e}"))
}

/// The directory a path's last name is in, and that name.
fn parent(fs: &mut Disk, path: &str) -> tryfs::Result<(i64, Vec<i32>)> {
    let p = cps(path);
    let last = fs.walk_path(ROOT_INO, &p)?;
    Ok((last.dir, p[last.start..last.end].to_vec()))
}

/// Make `path` a file holding `trytes`, made if missing.
fn put(fs: &mut Disk, path: &str, trytes: &[i64]) -> tryfs::Result<()> {
    let (dir, name) = parent(fs, path)?;
    let node = fs.iget(dir)?;
    let ino = match fs.lookup(&node, &name)? {
        Some(ino) => {
            if fs.iget(ino)?.is_dir() {
                return Err(E_ISDIR);
            }
            fs.truncate(ino)?;
            ino
        }
        None => fs.create(dir, &name, T_FILE, MODE_FILE)?.ino,
    };
    for (k, chunk) in trytes.chunks(PAGE as usize).enumerate() {
        let (b, _) = fs.bmap_alloc(ino, k as i64)?;
        fs.store.set_trytes(b, chunk);
    }
    let mut node = fs.iget(ino)?;
    node.size = trytes.len() as i64;
    node.mtime = fs.now;
    node.ctime = fs.now;
    fs.iput(&node)
}

/// The trytes of the file `path` names.
fn get(fs: &mut Disk, path: &str) -> tryfs::Result<Vec<i64>> {
    let ino = fs.resolve(ROOT_INO, &cps(path))?;
    let node = fs.iget(ino)?;
    if node.is_dir() {
        return Err(E_ISDIR);
    }
    let mut out = Vec::with_capacity(node.size as usize);
    let mut fb = 0;
    while (out.len() as i64) < node.size {
        let b = fs.bmap(ino, fb)?;
        if b == NO_BLOCK {
            out.extend(std::iter::repeat_n(0, PAGE as usize));
        } else {
            out.extend(fs.store.trytes(b));
        }
        fb += 1;
    }
    out.truncate(node.size as usize);
    Ok(out)
}

fn time_json(t: Time) -> String {
    format!("[{}, {}]", t.secs, t.nanos)
}

fn inode_json(fs: &mut Disk, name: Option<&str>, node: &Inode) -> tryfs::Result<String> {
    let mut blocks = 0;
    let mut it = Item::new();
    let mut k = tryfs::Key::extent(node.ino, -1);
    while fs.seek(&k, true, &mut it)? && it.key.ino() == node.ino && it.key.kind() == K_EXTENT {
        blocks += it.value[EX_LEN as usize];
        k = it.key;
    }
    let name = match name {
        Some(n) => format!("\"name\": {:?}, ", n),
        None => String::new(),
    };
    Ok(format!(
        "{{{name}\"ino\": {}, \"type\": {}, \"mode\": {}, \"uid\": {}, \"gid\": {}, \"links\": {}, \"size\": {}, \"blocks\": {}, \"parent\": {}, \"atime\": {}, \"mtime\": {}, \"ctime\": {}, \"btime\": {}}}",
        node.ino,
        node.typ,
        node.mode,
        node.uid,
        node.gid,
        node.links,
        node.size,
        blocks,
        node.parent,
        time_json(node.atime),
        time_json(node.mtime),
        time_json(node.ctime),
        time_json(node.btime),
    ))
}

/// Where the boot record's words are, from a block's first word.
fn word_of(offset: i64) -> usize {
    ((offset - BLOCK_W0) / 3) as usize
}

/// The boot record's blocks: (first, count), if there is one.
fn boot_record(fs: &mut Disk) -> tryfs::Result<Option<(i64, i64)>> {
    let s = fs.store.load(0)?;
    if fs.store.word(s, word_of(FS_HEAD_BOOT)) != BOOT_MAGIC {
        return Ok(None);
    }
    Ok(Some((fs.store.word(s, word_of(BOOT_FIRST)), fs.store.word(s, word_of(BOOT_COUNT)))))
}

/// No boot record: its blocks are free again.
fn noboot(fs: &mut Disk) -> tryfs::Result<()> {
    if let Some((first, n)) = boot_record(fs)? {
        for b in first..first + n {
            fs.release(b);
        }
    }
    let s = fs.store.load(0)?;
    for at in [FS_HEAD_BOOT, BOOT_FIRST, BOOT_COUNT, BOOT_PAGE, BOOT_ENTRY] {
        fs.store.set_word(s, word_of(at), 0);
    }
    Ok(())
}

/// Put `image`'s trytes in the first run of free blocks long enough, and
/// make the boot record name them.
fn boot(fs: &mut Disk, image: &[i64], page: i64, entry: i64) -> tryfs::Result<()> {
    noboot(fs)?;
    let n = (image.len() as i64 + PAGE - 1) / PAGE;
    let mut first = 1;
    let mut run = 0;
    let mut b = 1;
    while run < n && b < fs.blocks {
        if fs.in_use(b) {
            run = 0;
            first = b + 1;
        } else {
            run += 1;
        }
        b += 1;
    }
    if run < n {
        return Err(E_NOSPC);
    }
    for (k, chunk) in image.chunks(PAGE as usize).enumerate() {
        let b = first + k as i64;
        if !fs.alloc_at(b) {
            return Err(E_IO);
        }
        fs.store.zero(b)?;
        fs.store.set_trytes(b, chunk);
    }
    let s = fs.store.load(0)?;
    for (at, w) in [(FS_HEAD_BOOT, BOOT_MAGIC), (BOOT_FIRST, first), (BOOT_COUNT, n), (BOOT_PAGE, page), (BOOT_ENTRY, entry)] {
        fs.store.set_word(s, word_of(at), w);
    }
    Ok(())
}

fn info(fs: &mut Disk) -> tryfs::Result<String> {
    let free: Vec<String> = (1..fs.blocks).filter(|&b| !fs.in_use(b)).map(|b| b.to_string()).collect();
    let boot = match boot_record(fs)? {
        Some((first, n)) => format!("[{first}, {n}]"),
        None => String::from("null"),
    };
    Ok(format!(
        "{{\"blocks\": {}, \"disk_blocks\": {}, \"free\": [{}], \"inodes\": {}, \"next_ino\": {}, \"root\": {}, \"seq\": {}, \"boot\": {boot}}}",
        fs.blocks,
        fs.store.len(),
        free.join(", "),
        fs.inodes,
        fs.next_ino,
        fs.root,
        fs.seq,
    ))
}

fn number(s: &str) -> Result<i64, String> {
    s.parse().map_err(|_| format!("not a number: {s}"))
}

/// Run one command on a mounted filesystem: what to print.
fn command(fs: &mut Disk, args: &[&str]) -> Result<String, String> {
    let fail = |e: i64| error_name(e);
    let arg = |i: usize| args.get(i).copied().ok_or_else(|| format!("{}: too few arguments", args[0]));
    let out = match args[0] {
        "mkdir" => {
            let (dir, name) = parent(fs, arg(1)?).map_err(fail)?;
            fs.create(dir, &name, T_DIR, MODE_DIR).map_err(fail)?;
            String::new()
        }
        "put" => {
            let trytes = read_trytes(arg(2)?)?;
            put(fs, arg(1)?, &trytes).map_err(fail)?;
            String::new()
        }
        "get" => {
            let trytes = get(fs, arg(1)?).map_err(fail)?;
            write_trytes(arg(2)?, &trytes)?;
            String::new()
        }
        "rm" => {
            let (dir, name) = parent(fs, arg(1)?).map_err(fail)?;
            fs.unlink(dir, &name).map_err(fail)?;
            String::new()
        }
        "rmdir" => {
            let (dir, name) = parent(fs, arg(1)?).map_err(fail)?;
            fs.rmdir(dir, &name).map_err(fail)?;
            String::new()
        }
        "mv" => {
            let (fdir, from) = parent(fs, arg(1)?).map_err(fail)?;
            let (tdir, to) = parent(fs, arg(2)?).map_err(fail)?;
            fs.rename(fdir, &from, tdir, &to).map_err(fail)?;
            String::new()
        }
        "chmod" | "chown" | "utimes" => {
            let ino = fs.resolve(ROOT_INO, &cps(arg(1)?)).map_err(fail)?;
            let mut node = fs.iget(ino).map_err(fail)?;
            match args[0] {
                "chmod" => node.mode = number(arg(2)?)?,
                "chown" => {
                    node.uid = number(arg(2)?)?;
                    node.gid = number(arg(3)?)?;
                }
                _ => {
                    node.atime = Time { secs: number(arg(2)?)?, nanos: 0 };
                    node.mtime = Time { secs: number(arg(3)?)?, nanos: 0 };
                }
            }
            node.ctime = fs.now;
            fs.iput(&node).map_err(fail)?;
            String::new()
        }
        "ls" => {
            let dir = fs.resolve(ROOT_INO, &cps(arg(1)?)).map_err(fail)?;
            if !fs.iget(dir).map_err(fail)?.is_dir() {
                return Err(fail(E_NOTDIR));
            }
            let mut lines = String::new();
            let mut it = Item::new();
            let mut after = None;
            while fs.next_entry(dir, after.as_ref(), &mut it).map_err(fail)? {
                let mut name = [0; NAME_LEN];
                let n = it.key.name(&mut name);
                let key = it.key;
                let node = fs.iget(it.value[DE_INO as usize]).map_err(fail)?;
                lines += &inode_json(fs, Some(&text(&name[..n])), &node).map_err(fail)?;
                lines.push('\n');
                after = Some(key);
            }
            lines
        }
        "stat" | "istat" => {
            let ino = match args[0] {
                "stat" => fs.resolve(ROOT_INO, &cps(arg(1)?)).map_err(fail)?,
                _ => number(arg(1)?)?,
            };
            let node = fs.iget(ino).map_err(fail)?;
            let json = inode_json(fs, None, &node).map_err(fail)?;
            let mut data = Vec::new();
            let files = if node.is_dir() { 0 } else { (node.size + PAGE - 1) / PAGE };
            for fb in 0..files {
                data.push(fs.bmap(ino, fb).map_err(fail)?.to_string());
            }
            format!("{}, \"data\": [{}]}}\n", &json[..json.len() - 1], data.join(", "))
        }
        "info" => info(fs).map_err(fail)? + "\n",
        "check" => {
            let bad = check::check(fs);
            if !bad.is_empty() {
                return Err(bad.join("\n"));
            }
            String::new()
        }
        "boot" => {
            let image = read_trytes(arg(1)?)?;
            boot(fs, &image, number(arg(2)?)?, number(arg(3)?)?).map_err(fail)?;
            String::new()
        }
        "noboot" => {
            noboot(fs).map_err(fail)?;
            String::new()
        }
        other => return Err(format!("no command {other}")),
    };
    Ok(out)
}

fn run(args: &[String]) -> Result<(), String> {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["new", image, blocks, rest @ ..] => {
            let blocks = number(blocks)?;
            let disk = match rest.first() {
                Some(n) => number(n)?,
                None => blocks,
            };
            if disk < blocks {
                return Err(String::from("the disk is smaller than the filesystem"));
            }
            let mut fs = Fs::new(MemStore::new(disk as usize));
            fs.now = now();
            fs.format(blocks).map_err(error_name)?;
            save(&fs, image)
        }
        ["batch", image] => {
            let mut fs = load(image)?;
            for line in io::stdin().lock().lines() {
                let line = line.map_err(|e| e.to_string())?;
                if line.is_empty() {
                    continue;
                }
                let fields: Vec<&str> = line.split('\t').collect();
                match command(&mut fs, &fields) {
                    Ok(out) => {
                        print!("{out}");
                        fs.commit().map_err(error_name)?;
                    }
                    Err(e) => {
                        fs.abort();
                        return Err(format!("{line}: {e}"));
                    }
                }
            }
            save(&fs, image)
        }
        [cmd, image, rest @ ..] => {
            let mut fs = load(image)?;
            let mut all = vec![*cmd];
            all.extend_from_slice(rest);
            let out = command(&mut fs, &all)?;
            print!("{out}");
            if fs.changed() {
                fs.commit().map_err(error_name)?;
                save(&fs, image)?;
            }
            Ok(())
        }
        _ => Err(String::from("usage: tryfs COMMAND IMAGE ARGS... (see tools/rust/tryfs/src/main.rs)")),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tryfs: {e}");
            ExitCode::FAILURE
        }
    }
}
