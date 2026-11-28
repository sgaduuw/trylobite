//! ifconfig [ADDRESS/PREFIX [GATEWAY]]: say the IP server's address, the
//! length of its network prefix, its gateway and the name server that
//! resolvers ask, as
//!
//!   inet 10.0.0.2/24 gateway 10.0.0.1 nameserver 10.0.0.3
//!
//! or set the first three: the gateway stays as it was if none is
//! given, and 0.0.0.0 means none. ifconfig nameserver ADDRESS sets the
//! name server, 0.0.0.0 for none. Exit with 0, 1 if the server refuses,
//! and 2 for bad arguments or no IP server.
#![no_std]

use trystd::net::{IpConfig, Ipv4Addr};
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

fn usage() -> i32 {
    let usage = "usage: ifconfig [ADDRESS/PREFIX [GATEWAY]], or ifconfig nameserver ADDRESS";
    Line::new().str(usage).eprint();
    2
}

/// An address, None for 0.0.0.0.
fn some(a: Ipv4Addr) -> Option<Ipv4Addr> {
    (!a.is_unspecified()).then_some(a)
}

/// An address, or "none".
fn shown(line: &mut Line, a: Option<Ipv4Addr>) {
    match a {
        Some(a) => line.ip(a),
        None => line.str("none"),
    };
}

fn refused() -> i32 {
    Line::new().str("ifconfig: the IP server refused").eprint();
    1
}

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let (first, second) = (args.next(), args.next());
    if args.next().is_some() {
        return usage();
    }
    if sys::IP.pid().is_err() {
        Line::new().str("ifconfig: no IP server").eprint();
        return 2;
    }
    if let (Some("nameserver"), Some(server)) = (first, second) {
        let Ok(server) = server.parse() else {
            return usage();
        };
        return match net::set_nameserver(some(server)) {
            Ok(()) => 0,
            Err(_) => refused(),
        };
    }
    let Ok(now) = net::config() else {
        Line::new().str("ifconfig: the IP server failed").eprint();
        return 1;
    };
    let Some(first) = first else {
        let server = net::nameserver().ok().flatten();
        let mut line = Line::new();
        line.str("inet ").ip(now.address).byte(b'/').num(now.prefix as i64).str(" gateway ");
        shown(&mut line, now.gateway);
        line.str(" nameserver ");
        shown(&mut line, server);
        return line.print().is_err() as i32;
    };
    let Some((address, prefix)) = first.split_once('/') else {
        return usage();
    };
    let (Ok(address), Some(prefix)) = (address.parse(), prefix_length(prefix)) else {
        return usage();
    };
    let gateway = match second {
        None => now.gateway,
        Some(g) => match g.parse() {
            Ok(g) => some(g),
            Err(_) => return usage(),
        },
    };
    match net::set_config(IpConfig { address, prefix, gateway }) {
        Ok(()) => 0,
        Err(_) => refused(),
    }
}

/// A prefix length, 0 to 32, in one or two digits.
fn prefix_length(s: &str) -> Option<u8> {
    if s.is_empty() || s.len() > 2 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n = s.bytes().fold(0, |n, b| n * 10 + (b - b'0'));
    (n <= 32).then_some(n)
}
