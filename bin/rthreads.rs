//! rthreads [N [T]]: count the primes below N (20,000 if not given) in T
//! threads (2 if not given, at most 9), each taking every T-th odd
//! number, and say how many harts ran them. The threads add to one
//! total behind a `Mutex`, and each notes which harts it found itself
//! on; on a machine of two harts or more they run at once (`detrytus
//! run --harts 2`), the program waiting in `join` meanwhile.
#![no_std]

use trystd::prelude::*;
use trystd::sync::{Arc, Mutex};

trystd::main!(run);

/// What the threads share: the primes found so far, and the harts that
/// ran any of them, a bit each by hart + 4 (the kernel's middle nine).
struct Tally {
    primes: u32,
    harts: u32,
}

fn run() -> i32 {
    let args: Vec<&str> = env::args().collect();
    let below = arg(&args, 1, 20_000, u32::MAX);
    let threads = arg(&args, 2, 2, 9);
    let (Some(below), Some(threads)) = (below, threads) else {
        eprintln!("usage: rthreads [N [T]]");
        return 2;
    };
    let tally = Arc::new(Mutex::new(Tally {
        primes: (below > 2) as u32, // 2, the one even prime
        harts: 0,
    }));
    let mut handles = Vec::new();
    for k in 0..threads {
        let tally = tally.clone();
        handles.push(thread::spawn(move || count(&tally, below, k, threads)));
    }
    for h in handles {
        let tid = h.id();
        let found = h.join().expect("join");
        println!("thread {tid}: {found} primes");
    }
    let t = tally.lock().unwrap();
    println!("primes below {below}: {}", t.primes);
    println!("harts used: {}", t.harts.count_ones());
    0
}

/// Argument `k` as a number from 1 to `max`, `default` if not given.
fn arg(args: &[&str], k: usize, default: u32, max: u32) -> Option<u32> {
    match args.get(k) {
        None => Some(default),
        Some(a) => a.parse().ok().filter(|&n| n >= 1 && n <= max),
    }
}

/// Count the primes among the odd numbers 3 + 2 * (k + step * i) below
/// `below`, adding them to the tally as it goes: how many it found.
fn count(tally: &Mutex<Tally>, below: u32, k: u32, step: u32) -> u32 {
    let mut found = 0;
    let mut batch = 0;
    let mut n = 3 + 2 * k;
    while n < below {
        if is_prime(n) {
            found += 1;
            batch += 1;
        }
        n += 2 * step;
        if batch == 50 || n >= below {
            // Now and then, so the lock is taken while others work.
            let mut t = tally.lock().unwrap();
            t.primes += batch;
            t.harts |= 1 << (thread::hart() + 4);
            batch = 0;
        }
    }
    found
}

/// Whether odd `n`, 3 or more, is prime: trial division by odd numbers.
fn is_prime(n: u32) -> bool {
    let mut d = 3;
    while d * d <= n {
        if n % d == 0 {
            return false;
        }
        d += 2;
    }
    true
}
