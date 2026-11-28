//! rsig: trystd's signals, tried from inside a program (tests/test_signals.py).
//! Handlers only count, in atomics; the program says what it found.
#![no_std]

use core::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use trystd::prelude::*;
use trystd::process::Command;
use trystd::signal::{self, Handler, SigSet};

trystd::main!(run);

static COUNT: AtomicI32 = AtomicI32::new(0);
static LAST: AtomicI32 = AtomicI32::new(0);
static TOOK: AtomicI32 = AtomicI32::new(-1);
static CHILDREN: AtomicI32 = AtomicI32::new(0);
static GO: AtomicBool = AtomicBool::new(false);

fn count(sig: i32) {
    COUNT.fetch_add(1, Ordering::SeqCst);
    LAST.store(sig, Ordering::SeqCst);
}

fn took(_: i32) {
    TOOK.store(thread::current_id(), Ordering::SeqCst);
}

fn child_ended(_: i32) {
    CHILDREN.fetch_add(1, Ordering::SeqCst);
}

fn run() -> io::Result<()> {
    let args: Vec<&str> = env::args().collect();
    if args.get(1) == Some(&"sleep") {
        loop {
            thread::sleep_ticks(100_000);
        }
    }

    signal::signal(signal::SIGUSR1, Handler::Catch(count))?;
    signal::raise(signal::SIGUSR1)?;
    println!("raised {} {}", COUNT.load(Ordering::SeqCst), LAST.load(Ordering::SeqCst));

    signal::signal(signal::SIGUSR2, Handler::Catch(count))?;
    signal::block(SigSet::of(&[signal::SIGUSR2]))?;
    signal::raise(signal::SIGUSR2)?;
    println!("blocked {}", COUNT.load(Ordering::SeqCst));
    let had = signal::unblock(SigSet::of(&[signal::SIGUSR2]))?;
    println!(
        "unblocked {} {} had {}",
        COUNT.load(Ordering::SeqCst),
        LAST.load(Ordering::SeqCst),
        had.contains(signal::SIGUSR2)
    );

    let was = signal::signal(signal::SIGTERM, Handler::Ignore)?;
    signal::raise(signal::SIGTERM)?;
    println!("ignored, was {was:?}");
    println!("kill refused {:?}", signal::signal(signal::SIGKILL, Handler::Ignore).is_err());

    signal::signal(signal::SIGALRM, Handler::Catch(count))?;
    let before = COUNT.load(Ordering::SeqCst);
    signal::alarm(2_000);
    // A sleep the alarm cuts short goes on to its end.
    thread::sleep_ticks(20_000);
    println!(
        "alarm {} {}",
        COUNT.load(Ordering::SeqCst) - before,
        LAST.load(Ordering::SeqCst)
    );

    // Blocked here, once the worker has started with this thread's mask
    // as it was, the signal can only go to the worker.
    signal::signal(signal::SIGUSR1, Handler::Catch(took))?;
    let worker = thread::spawn(|| {
        GO.store(true, Ordering::SeqCst);
        while TOOK.load(Ordering::SeqCst) < 0 {
            thread::yield_now();
        }
        thread::current_id()
    });
    signal::block(SigSet::of(&[signal::SIGUSR1]))?;
    while !GO.load(Ordering::SeqCst) {
        thread::yield_now();
    }
    signal::raise(signal::SIGUSR1)?;
    let tid = worker.join().unwrap_or(-2);
    println!("thread took it {}", TOOK.load(Ordering::SeqCst) == tid);
    signal::unblock(SigSet::of(&[signal::SIGUSR1]))?;

    signal::signal(signal::SIGCHLD, Handler::Catch(child_ended))?;
    // The child keeps the SIGTERM this process ignores: SIGINT ends it.
    let mut child = Command::new("rsig").arg("sleep").spawn()?;
    child.signal(signal::SIGTERM)?;
    child.signal(signal::SIGINT)?;
    let status = child.wait()?;
    println!("child {status} {:?} chld {}", status.signal(), CHILDREN.load(Ordering::SeqCst));
    Ok(())
}
