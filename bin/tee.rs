//! tee [-a] FILE...: standard input to standard output and to each FILE
//! as well, made or emptied first (appended to with -a), as Unix's tee.
//! A FILE that cannot be opened is said on standard error and left out,
//! and the exit code is then 1. In Rust, over trystd's fs and io.
#![no_std]

use trystd::fs::{File, OpenOptions};
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut append = false;
    let mut names: Vec<&str> = Vec::new();
    for arg in env::args().skip(1) {
        match arg {
            "-a" if names.is_empty() => append = true,
            _ => names.push(arg),
        }
    }
    let mut code = 0;
    let mut files: Vec<(&str, File)> = Vec::new();
    for name in names {
        let opened = if append {
            OpenOptions::new().append(true).create(true).open(name)
        } else {
            File::create(name)
        };
        match opened {
            Ok(file) => files.push((name, file)),
            Err(e) => {
                eprintln!("tee: {name}: {e}");
                code = 1;
            }
        }
    }
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut buf = [0u8; 243];
    loop {
        let n = match stdin.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                eprintln!("tee: {e}");
                return 1;
            }
        };
        if stdout
            .write_all(&buf[..n])
            .and_then(|()| stdout.flush())
            .is_err()
        {
            return 1;
        }
        files.retain_mut(|(name, file)| match file.write_all(&buf[..n]) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("tee: {name}: {e}");
                code = 1;
                false
            }
        });
    }
    code
}
