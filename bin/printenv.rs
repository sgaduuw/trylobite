//! printenv [NAME...]: the environment this program was started with,
//! as the shell's export gave it: every NAME=VALUE line, or with names,
//! each one's value alone. Exits with 1 if a name is not set, as Unix's
//! printenv does.
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

fn run() -> i32 {
    let mut out = io::stdout();
    let mut missing = 0;
    let mut said = Ok(());
    if env::args_bytes().len() == 1 {
        for (name, value) in env::vars_bytes() {
            said = said
                .and_then(|_| out.write_all(&name))
                .and_then(|_| out.write_all(b"="))
                .and_then(|_| out.write_all(&value))
                .and_then(|_| out.write_all(b"\n"));
        }
    }
    for name in env::args_bytes().skip(1) {
        match env::var_bytes(name) {
            Some(value) => {
                said = said.and_then(|_| out.write_all(&value)).and_then(|_| out.write_all(b"\n"));
            }
            None => missing = 1,
        }
    }
    let flushed = said.and_then(|_| out.flush());
    if flushed.is_err() { 1 } else { missing }
}
