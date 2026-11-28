//! ping HOST [COUNT]: send COUNT echo requests (3 if not given) to HOST,
//! an IPv4 address a.b.c.d or a name to resolve, through the IP server,
//! one after another, and say for each how many ticks its reply took, or
//! that none came in time, as Unix's ping -c does. Exit with 0 if any
//! reply came, 1 if none did, the name has no address or the network
//! failed, and 2 for bad arguments or no IP server.
#![no_std]

use trystd::io::ErrorKind;
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

/// Ticks to wait for each reply.
const WAIT: u32 = 100_000;

fn usage() -> i32 {
    Line::new().str("usage: ping HOST [COUNT]").eprint();
    2
}

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let (host, count) = match (args.next(), args.next(), args.next()) {
        (Some(host), None, _) => (host, 3),
        (Some(host), Some(n), None) => match number(n) {
            Some(c) if c > 0 => (host, c),
            _ => return usage(),
        },
        _ => return usage(),
    };
    if sys::IP.pid().is_err() {
        Line::new().str("ping: no IP server").eprint();
        return 2;
    }
    let to = match net::host_address(host) {
        Ok(a) => a,
        Err(e) => {
            Line::new().str("ping: ").str(host).str(": ").error(&e).eprint();
            return 1;
        }
    };
    let mut replies = 0;
    let mut line = Line::new();
    for seq in 1..=count {
        match net::ping(to, (seq % 65536) as u16, WAIT) {
            Ok(took) => {
                replies += 1;
                line.str("reply from ").str(host).str(": seq ").num(seq as i64);
                line.str(", ").num(took as i64).str(" ticks");
            }
            Err(e) if e.kind() == ErrorKind::TimedOut => {
                line.str("no reply from ").str(host).str(": seq ").num(seq as i64);
            }
            Err(e) => {
                let why = match e.raw_os_error() {
                    Some(sys::E_NOROUTE) => "no route there",
                    Some(sys::E_IO) => "the network is down",
                    Some(sys::E_BUSY) => "another ping is under way",
                    _ => "failed",
                };
                Line::new().str("ping: ").str(host).str(": ").str(why).eprint();
                return 1;
            }
        }
        if line.print().is_err() {
            return 1;
        }
    }
    if replies > 0 { 0 } else { 1 }
}

/// A number of up to six decimal digits.
fn number(s: &str) -> Option<u32> {
    if s.is_empty() || s.len() > 6 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(s.bytes().fold(0, |n, b| n * 10 + (b - b'0') as u32))
}
