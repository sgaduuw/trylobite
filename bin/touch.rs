//! touch FILE...: make each FILE that is not there yet, empty, and set
//! the access and modification times of each one to now, as Unix's
//! touch does. Exit with 0, or with 1 if one cannot be made or changed
//! (said on standard error).
#![no_std]

use trystd::fs::{self, OpenOptions};
use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let names = env::args().skip(1);
    if names.len() == 0 {
        Line::new().str("usage: touch FILE...").eprint();
        return 1;
    }
    let mut status = 0;
    for name in names {
        let made = OpenOptions::new().read(true).create(true).open(name);
        if let Err(e) = made.and_then(|f| {
            drop(f);
            fs::touch_now(name)
        }) {
            Line::new().str("touch: ").str(name).str(": ").error(&e).eprint();
            status = 1;
        }
    }
    status
}
