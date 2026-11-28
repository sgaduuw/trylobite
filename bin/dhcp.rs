//! dhcp [-d] [-n]: ask the network for an address by DHCP (RFC 2131)
//! and give it to the IP server: the address and its prefix length,
//! the gateway and the name server, which it prints as ifconfig does,
//! with the lease:
//!
//!   inet 10.0.0.15/24 gateway 10.0.0.1 nameserver 10.0.0.3 lease 86400 s
//!
//! It broadcasts a DISCOVER from UDP port 68, takes the first OFFER,
//! REQUESTs it and sets what the ACK says. -n asks the same and prints
//! it, setting nothing. -d is the daemon /etc/init starts: it keeps the
//! lease, asking again at half of it (a REQUEST for the address it has,
//! to everyone), and starts over after RETRY if nobody answers; with no
//! answer to its first DISCOVER it keeps the address it had (10.0.0.2
//! until set), and says so only once QUIET rounds in a row have failed.
//!
//! What a client asks from is the IP server's current address rather
//! than 0.0.0.0, which RFC 2131 says: the machine keeps working while it
//! asks. Servers answer to everyone, and the IP server takes what comes
//! to 255.255.255.255 as if to us. Exit 0 with an address, 1 with none,
//! 2 for bad arguments. In Rust, over trystd's net.
#![no_std]

use trystd::net::{self, IpConfig, Ipv4Addr, UdpSocket};
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

const CLIENT: u16 = 68;
const SERVER: u16 = 67;
const WAIT: u32 = 1_000_000; // ticks to wait for an answer: a second,
const TRIES: usize = 4; // and how many times to ask, the wait doubling
const RETRY: i64 = 60_000_000; // ticks before a daemon that got nothing asks again
const QUIET: u32 = 3; // failed rounds in a row before one is reported
const TICKS: i64 = 1_000_000; // a second

/// What a message is: its fixed part, the cookie, and the types used.
const OPTIONS: usize = 240;
const MAGIC: [u8; 4] = [99, 130, 83, 99];
const DISCOVER: u8 = 1;
const OFFER: u8 = 2;
const REQUEST: u8 = 3;
const ACK: u8 = 5;
const NAK: u8 = 6;
/// Options.
const PAD: u8 = 0;
const MASK: u8 = 1;
const ROUTER: u8 = 3;
const DNS: u8 = 6;
const REQUESTED: u8 = 50;
const LEASE: u8 = 51;
const TYPE: u8 = 53;
const SERVER_ID: u8 = 54;
const PARAMS: u8 = 55;
const END: u8 = 255;
const MSG_MAX: usize = 576; // the most a client must take

fn usage() -> i32 {
    Line::new().str("usage: dhcp [-d] [-n]").eprint();
    2
}

/// What a server offered or acknowledged.
#[derive(Clone, Copy)]
struct Lease {
    address: Ipv4Addr,
    prefix: u8,
    gateway: Option<Ipv4Addr>,
    nameserver: Option<Ipv4Addr>,
    server: Ipv4Addr,
    secs: u32,
}

fn run() -> i32 {
    let (mut daemon, mut show) = (false, false);
    for arg in env::args().skip(1) {
        match arg {
            "-d" => daemon = true,
            "-n" => show = true,
            _ => return usage(),
        }
    }
    if daemon && show {
        return usage();
    }
    let mut client = match Client::new() {
        Ok(c) => c,
        Err(e) => {
            Line::new().str("dhcp: ").error(&e).eprint();
            return 1;
        }
    };
    if !daemon {
        let Some(lease) = client.obtain() else {
            let why = if client.refused { "the DHCP server refused" } else { "no DHCP server answered" };
            Line::new().str("dhcp: ").str(why).eprint();
            return 1;
        };
        if !show && set(&lease).is_err() {
            Line::new().str("dhcp: the IP server refused").eprint();
            return 1;
        }
        return say(&lease, false);
    }
    let mut failures = 0;
    let mut held: Option<Lease> = None;
    loop {
        let got = match held {
            Some(_) => client.renew().or_else(|| client.obtain()),
            None => client.obtain(),
        };
        let wait = match got {
            Some(lease) => {
                let changed = held.is_none_or(|h| h.address != lease.address);
                if set(&lease).is_ok() && changed {
                    say(&lease, true);
                }
                held = Some(lease);
                failures = 0;
                (lease.secs as i64 * TICKS / 2).max(RETRY)
            }
            None => {
                failures += 1;
                if failures == QUIET {
                    Line::new().str("dhcp: no DHCP server answered").eprint();
                }
                RETRY
            }
        };
        sys::sleep_until(sys::ticks() + wait);
    }
}

/// Give the lease to the IP server.
fn set(lease: &Lease) -> io::Result<()> {
    net::set_config(IpConfig {
        address: lease.address,
        prefix: lease.prefix,
        gateway: lease.gateway,
    })?;
    if lease.nameserver.is_some() {
        net::set_nameserver(lease.nameserver)?;
    }
    Ok(())
}

/// Print it, as ifconfig does, with "dhcp: " in front for the console.
fn say(lease: &Lease, named: bool) -> i32 {
    let mut line = Line::new();
    if named {
        line.str("dhcp: ");
    }
    line.str("inet ").ip(lease.address).byte(b'/').num(lease.prefix as i64);
    line.str(" gateway ");
    match lease.gateway {
        Some(g) => line.ip(g),
        None => line.str("none"),
    };
    line.str(" nameserver ");
    match lease.nameserver {
        Some(n) => line.ip(n),
        None => line.str("none"),
    };
    line.str(" lease ").num(lease.secs as i64).str(" s");
    line.print().is_err() as i32
}

struct Client {
    socket: UdpSocket,
    mac: [u8; 6],
    xid: u32,
    /// The last exchange ended with a NAK.
    refused: bool,
}

impl Client {
    fn new() -> io::Result<Client> {
        let mac = net::mac_address()?;
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, CLIENT))?;
        let xid = (sys::ticks() as u32) ^ u32::from_be_bytes([mac[2], mac[3], mac[4], mac[5]]);
        Ok(Client { socket, mac, xid, refused: false })
    }

    /// DISCOVER, then REQUEST what is offered: the lease acknowledged.
    fn obtain(&mut self) -> Option<Lease> {
        self.xid = self.xid.wrapping_add(1);
        let offer = self.exchange(DISCOVER, None, None, OFFER)?;
        self.exchange(REQUEST, Some(offer.address), Some(offer.server), ACK)
    }

    /// Ask to keep the address it has: a REQUEST from it, to everyone.
    fn renew(&mut self) -> Option<Lease> {
        self.xid = self.xid.wrapping_add(1);
        self.exchange(REQUEST, None, None, ACK)
    }

    /// Send a message of type `kind` to everyone, with the options
    /// requested address and server identifier if given, and wait for an
    /// answer of type `want` to it, asking again as it waits longer.
    fn exchange(
        &mut self,
        kind: u8,
        requested: Option<Ipv4Addr>,
        server: Option<Ipv4Addr>,
        want: u8,
    ) -> Option<Lease> {
        let mut m = [0u8; 300];
        m[..4].copy_from_slice(&[1, 1, 6, 0]); // a request, on Ethernet
        m[4..8].copy_from_slice(&self.xid.to_be_bytes());
        m[10] = 0x80; // answer to everyone
        if kind == REQUEST && requested.is_none() {
            // Renewing: the address it has is the one asked for.
            let me = net::local_address().ok()?;
            m[12..16].copy_from_slice(&me.octets());
        }
        m[28..34].copy_from_slice(&self.mac);
        m[OPTIONS - 4..OPTIONS].copy_from_slice(&MAGIC);
        let mut at = OPTIONS;
        let mut put = |bytes: &[u8]| {
            m[at..at + bytes.len()].copy_from_slice(bytes);
            at += bytes.len();
        };
        put(&[TYPE, 1, kind]);
        if let Some(a) = requested {
            put(&[REQUESTED, 4]);
            put(&a.octets());
        }
        if let Some(s) = server {
            put(&[SERVER_ID, 4]);
            put(&s.octets());
        }
        put(&[PARAMS, 3, MASK, ROUTER, DNS, END]);
        self.refused = false;
        let mut wait = WAIT;
        let mut got = [0u8; MSG_MAX];
        for _ in 0..TRIES {
            self.socket.send_to(&m, (Ipv4Addr::BROADCAST, SERVER)).ok()?;
            let _ = self.socket.set_read_timeout_ticks(Some(wait));
            loop {
                match self.socket.recv_from(&mut got) {
                    Ok((n, from)) if from.port() == SERVER => {
                        match self.answer(&got[..n]) {
                            Some((k, lease)) if k == want => return Some(lease),
                            Some((NAK, _)) => {
                                self.refused = true;
                                return None;
                            }
                            _ => {}
                        }
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == io::ErrorKind::TimedOut => break,
                    Err(e) if e.raw_os_error() == Some(sys::E_NOROOM) => {}
                    Err(_) => return None,
                }
            }
            wait = wait.saturating_mul(2);
        }
        None
    }

    /// A server's answer to our transaction: its type and what it says.
    fn answer(&self, m: &[u8]) -> Option<(u8, Lease)> {
        if m.len() < OPTIONS || m[0] != 2 || m[4..8] != self.xid.to_be_bytes() {
            return None;
        }
        if m[28..34] != self.mac || m[OPTIONS - 4..OPTIONS] != MAGIC {
            return None;
        }
        let ip = |b: &[u8]| Ipv4Addr::new(b[0], b[1], b[2], b[3]);
        let mut lease = Lease {
            address: ip(&m[16..20]),
            prefix: 24,
            gateway: None,
            nameserver: None,
            server: ip(&m[20..24]),
            secs: 0,
        };
        let mut kind = 0;
        let mut o = &m[OPTIONS..];
        while let [code, rest @ ..] = o {
            if *code == PAD {
                o = rest;
                continue;
            }
            if *code == END {
                break;
            }
            let [len, rest @ ..] = rest else { break };
            let len = *len as usize;
            if rest.len() < len {
                break;
            }
            let v = &rest[..len];
            match (*code, len) {
                (TYPE, 1) => kind = v[0],
                (MASK, 4) => lease.prefix = u32::from_be_bytes([v[0], v[1], v[2], v[3]]).count_ones() as u8,
                (ROUTER, 4..) => lease.gateway = Some(ip(v)),
                (DNS, 4..) => lease.nameserver = Some(ip(v)),
                (SERVER_ID, 4) => lease.server = ip(v),
                (LEASE, 4) => lease.secs = u32::from_be_bytes([v[0], v[1], v[2], v[3]]),
                _ => {}
            }
            o = &rest[len..];
        }
        if kind != NAK && lease.address.is_unspecified() {
            return None;
        }
        Some((kind, lease))
    }
}
