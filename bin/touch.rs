//! touch FILE...: make each FILE that is not there yet, empty, as Unix's
//! touch does; one that is there is left as it is, since files have no
//! times to bring up to date. Exit with 0, or with 1 if one cannot be
//! made (said on standard error).
#![no_std]

use trystd::fs::OpenOptions;
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
        if let Err(e) = OpenOptions::new().read(true).create(true).open(name) {
            Line::new().str("touch: ").str(name).str(": ").error(&e).eprint();
            status = 1;
        }
    }
    status
}
