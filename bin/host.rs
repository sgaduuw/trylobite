//! host NAME [SERVER]: say the IPv4 addresses of the host NAME, one line
//! each, as
//!
//!   example.org has address 93.184.215.14
//!
//! asking the IP server's name server (IP_NAMESERVER), or the one at
//! address SERVER, as Unix's host does. Exit with 0, 1 if the name has
//! no address or the lookup failed, and 2 for bad arguments or no IP
//! server.
#![no_std]

use trystd::net::Ipv4Addr;
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let (name, server) = match (args.next(), args.next(), args.next()) {
        (Some(name), None, _) => (name, None),
        (Some(name), Some(server), None) => match server.parse::<Ipv4Addr>() {
            Ok(s) => (name, Some(s)),
            Err(_) => return usage(),
        },
        _ => return usage(),
    };
    if sys::IP.pid().is_err() {
        Line::new().str("host: no IP server").eprint();
        return 2;
    }
    let found = match server {
        Some(s) => net::lookup_host_at(name, s),
        None => net::lookup_host(name),
    };
    match found {
        Ok(addresses) => {
            let mut line = Line::new();
            for a in addresses {
                if line.str(name).str(" has address ").ip(a).print().is_err() {
                    return 1;
                }
            }
            0
        }
        Err(e) => {
            Line::new().str("host: ").str(name).str(": ").error(&e).eprint();
            1
        }
    }
}

fn usage() -> i32 {
    Line::new().str("usage: host NAME [SERVER]").eprint();
    2
}
