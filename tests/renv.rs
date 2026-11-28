//! renv: a test of the environment from inside a program (trystd::env
//! and the kernel's environ): each check prints a line saying what it
//! found, which tests/test_env.py compares with what it should be.
#![no_std]

use trystd::prelude::*;
use trystd::process::Command;
use trystd::sys;

trystd::main!(run);

fn run() -> io::Result<()> {
    println!("start {:?}", env::var("GREETING"));
    env::set_var("A", "one")?;
    env::set_var("B", "two")?;
    env::set_var("A", "uno")?;
    env::remove_var("GREETING")?;
    println!("vars {:?}", env::vars().collect::<Vec<_>>());
    println!("missing {:?}", env::var("GREETING"));
    // A child gets the environment as it is now, and one Command adds.
    let out = Command::new("printenv").env("C", "three").env_remove("B").output()?;
    println!("child {:?}", String::from_utf8_lossy(&out.stdout));
    println!("after {:?}", env::var("C"));
    for bad in ["", "x=y"] {
        println!("name {bad:?} {}", env::set_var(bad, "v").unwrap_err());
    }
    // A block past ENV_MAX does not take, and the old one stays.
    let big = vec![b'x'; sys::ENV_MAX as usize];
    println!("big {}", env::set_var("BIG", &big).unwrap_err());
    println!("kept {:?}", env::var("A"));
    // The kernel checks the block it is given.
    println!("fault {}", sys::call(sys::SYS_ENVIRON, &[-1]) == sys::E_FAULT);
    let unended = vec![b'y'; sys::ENV_MAX as usize + 9];
    println!("unended {}", sys::call(sys::SYS_ENVIRON, &[unended.as_ptr() as i32]) == sys::E_2BIG);
    let out = Command::new("printenv").output()?;
    println!("still {:?}", String::from_utf8_lossy(&out.stdout));
    Ok(())
}
