//! chmod MODE FILE...: give each FILE the permissions MODE, in octal
//! (755, 0644), as Unix's chmod with a numeric mode. Exit with 0, or
//! with 1 if one cannot be changed (said on standard error).
#![no_std]

use trystd::fs::{self, Permissions};
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let mode = args.next().and_then(octal);
    let (Some(mode), true) = (mode, args.len() > 0) else {
        Line::new().str("usage: chmod MODE FILE... (MODE in octal, such as 644)").eprint();
        return 2;
    };
    let mut status = 0;
    for file in args {
        if let Err(e) = fs::set_permissions(file, Permissions::from_mode(mode)) {
            Line::new().str("chmod: ").str(file).str(": ").error(&e).eprint();
            status = 1;
        }
    }
    status
}

fn octal(s: &str) -> Option<u32> {
    if s.is_empty() || s.len() > 4 || !s.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
        return None;
    }
    let n = s.bytes().fold(0, |n, b| n * 8 + (b - b'0') as u32);
    (n <= 0o777).then_some(n)
}
