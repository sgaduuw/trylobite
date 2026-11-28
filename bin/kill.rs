//! kill [-SIGNAL] PID... and kill -l: send each process named a signal,
//! SIGTERM unless one is given, by name (-INT, -SIGINT, -s INT) or
//! number (-9), as Unix's kill does. Any process but init, since there
//! are no users to tell apart; a server that ends is started again by
//! init. -l lists the signals. Exit with 0, with 1 if a process could
//! not be signalled (said on standard error), or with 2 for a bad
//! signal or process number. In Rust, over trystd's signal.
#![no_std]

use trystd::prelude::*;
use trystd::signal;
use trystd::sys;

trystd::main!(run);

fn usage() -> i32 {
    eprintln!("usage: kill [-SIGNAL] PID... | kill -l");
    2
}

/// The number `s` writes in decimal: a few digits, no sign.
fn number(s: &str) -> Option<i32> {
    if s.is_empty() || s.len() > 6 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(s.bytes().fold(0, |n, b| n * 10 + (b - b'0') as i32))
}

/// The signal an option names: a number or a name.
fn parse_signal(s: &str) -> Option<i32> {
    match number(s) {
        Some(n) => (n < sys::NSIG).then_some(n),
        None => signal::by_name(s),
    }
}

fn run() -> i32 {
    let args: Vec<&str> = env::args().skip(1).collect();
    let mut sig = signal::SIGTERM;
    let mut rest = &args[..];
    match rest.first().copied() {
        Some("-l") => {
            for (n, name) in signal::NAMES {
                println!("{n:2} {name}");
            }
            return 0;
        }
        Some("-s") => {
            let Some(s) = rest.get(1).and_then(|s| parse_signal(s)) else {
                return usage();
            };
            sig = s;
            rest = &rest[2..];
        }
        Some(opt) if opt.len() > 1 && opt.starts_with('-') => {
            let Some(s) = parse_signal(&opt[1..]) else {
                eprintln!("kill: {opt}: no such signal");
                return 2;
            };
            sig = s;
            rest = &rest[1..];
        }
        _ => {}
    }
    if rest.is_empty() {
        return usage();
    }
    let mut code = 0;
    for &arg in rest {
        let Some(pid) = number(arg) else {
            return usage();
        };
        if let Err(e) = signal::kill(pid, sig) {
            let why = match e.raw_os_error() {
                Some(sys::E_NOPROC) => "no such process",
                Some(sys::E_PERM) => "not allowed",
                _ => "cannot signal it",
            };
            eprintln!("kill: {arg}: {why}");
            code = 1;
        }
    }
    code
}
