//! dhcpsd ADDRESS [nak]: a DHCP server for the tests, on UDP port 67,
//! which offers ADDRESS/24 with 10.0.0.1 as the router, 10.0.0.9 as the
//! name server and a lease of 7,200 s, acknowledges a REQUEST for it and
//! refuses (NAK) one for any other address; with "nak" it refuses every
//! REQUEST. `dhcpsd 10.0.0.42 | dhcp` runs the two side by side over a
//! loop link, as tests/ntpsd.rs is run; it ends once nothing has come
//! for IDLE ticks. Its answers go to everyone, as a real server's do.
#![no_std]

use trystd::net::{Ipv4Addr, UdpSocket};
use trystd::prelude::*;

trystd::main!(run);

const IDLE: u32 = 6_000_000;
const OPTIONS: usize = 240;

fn run() -> io::Result<i32> {
    let mut args = env::args().skip(1);
    let Some(Ok(offered)) = args.next().map(|a| a.parse::<Ipv4Addr>()) else {
        Line::new().str("usage: dhcpsd ADDRESS [nak]").eprint();
        return Ok(2);
    };
    let refuse = args.next() == Some("nak");
    let mut socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 67))?;
    socket.set_read_timeout_ticks(Some(IDLE))?;
    let mut m = [0u8; 576];
    loop {
        let n = match socket.recv_from(&mut m) {
            Ok((n, _)) => n,
            Err(e) if e.kind() == io::ErrorKind::TimedOut => return Ok(0),
            Err(e) => return Err(e),
        };
        if n < OPTIONS + 3 || m[0] != 1 || m[OPTIONS] != 53 {
            continue;
        }
        let kind = m[OPTIONS + 2];
        // The address asked for: option 50 if it comes next, else ciaddr.
        let wanted = if m[OPTIONS + 3] == 50 {
            &m[OPTIONS + 5..OPTIONS + 9]
        } else {
            &m[12..16]
        };
        let answer = match kind {
            1 => 2,
            3 if !refuse && wanted == offered.octets() => 5,
            3 => 6,
            _ => continue,
        };
        let mut r = [0u8; 300];
        r[..4].copy_from_slice(&[2, 1, 6, 0]);
        r[4..8].copy_from_slice(&m[4..8]);
        r[10..12].copy_from_slice(&m[10..12]);
        if answer != 6 {
            r[16..20].copy_from_slice(&offered.octets());
        }
        r[20..24].copy_from_slice(&[10, 0, 0, 1]);
        r[28..44].copy_from_slice(&m[28..44]);
        r[OPTIONS - 4..OPTIONS].copy_from_slice(&[99, 130, 83, 99]);
        let options: &[u8] = &[
            53, 1, answer, 54, 4, 10, 0, 0, 1, 51, 4, 0, 0, 0x1c, 0x20, 1, 4, 255, 255, 255, 0, 3,
            4, 10, 0, 0, 1, 6, 4, 10, 0, 0, 9, 255,
        ];
        let options = if answer == 6 { &[53, 1, 6, 54, 4, 10, 0, 0, 1, 255][..] } else { options };
        r[OPTIONS..OPTIONS + options.len()].copy_from_slice(options);
        socket.send_to(&r, (Ipv4Addr::BROADCAST, 68))?;
    }
}
