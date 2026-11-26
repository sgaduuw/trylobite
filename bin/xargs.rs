//! xargs [COMMAND [ARG...]]: run COMMAND (echo if not given) with the
//! ARGs and then the words of standard input, as Unix's xargs: as many
//! words at a time as the kernel's ARG_MAX lets one command take, and as
//! many times as it takes for all of them (once, with none, if there are
//! none). The exit code is 0, 123 if a
//! command failed, or 127 if it could not be run. In Rust, over
//! trystd's process.
#![no_std]

use trystd::prelude::*;
use trystd::process::Command;
use trystd::sys::ARG_MAX;

trystd::main!(run);

/// Trytes an argument takes in the kernel's argument block: its 0 too.
fn size(arg: &str) -> usize {
    arg.len() + 1
}

fn run() -> i32 {
    let mut fixed: Vec<&str> = env::args().skip(1).collect();
    if fixed.is_empty() {
        fixed.push("echo");
    }
    let mut input = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut input) {
        eprintln!("xargs: {e}");
        return 1;
    }
    let room = ARG_MAX as usize - fixed.iter().map(|a| size(a)).sum::<usize>();
    let mut words = input.split_ascii_whitespace().peekable();
    let mut code = 0;
    loop {
        let mut batch: Vec<&str> = Vec::new();
        let mut used = 0;
        while let Some(&word) = words.peek() {
            if used + size(word) > room && !batch.is_empty() {
                break;
            }
            used += size(word);
            batch.push(word);
            words.next();
        }
        match Command::new(fixed[0])
            .args(&fixed[1..])
            .args(&batch)
            .status()
        {
            Ok(status) if status.success() => {}
            Ok(_) => code = 123,
            Err(e) => {
                eprintln!("xargs: {}: {e}", fixed[0]);
                return 127;
            }
        }
        if words.peek().is_none() {
            return code;
        }
    }
}
