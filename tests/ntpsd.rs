//! ntpsd OFFSET: an NTP server for the tests, on UDP port 123, whose
//! time is the machine's own clock moved by OFFSET seconds, so that
//! bin/ntpd finds the clock OFFSET seconds off. `ntpsd 60 | ntpd -n
//! 10.0.0.2` runs the two side by side, as tests/dnsd.tc is run; it
//! ends once no question has come for IDLE ticks. OFFSET "kiss" answers with a kiss
//! of death instead, as a server that will not serve does.
#![no_std]

use trystd::net::{Ipv4Addr, UdpSocket};
use trystd::prelude::*;
use trystd::time::{SystemTime, UNIX_EPOCH};

trystd::main!(run);

const IDLE: u32 = 3_000_000;
const NTP_UNIX: u64 = 2_208_988_800;

fn run() -> io::Result<i32> {
    let mut args = env::args().skip(1);
    let offset = args.next().unwrap_or("0");
    let kiss = offset == "kiss";
    let offset: u64 = if kiss { 0 } else { offset.bytes().fold(0, |n, b| n * 10 + (b - b'0') as u64) };
    let mut socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 123))?;
    socket.set_read_timeout_ticks(Some(IDLE))?;
    let mut got = [0u8; 48];
    loop {
        let (n, from) = match socket.recv_from(&mut got) {
            Ok(x) => x,
            Err(e) if e.kind() == io::ErrorKind::TimedOut => return Ok(0),
            Err(e) => return Err(e),
        };
        if n < 48 || got[0] & 7 != 3 {
            continue;
        }
        let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let secs = d.as_secs() + offset + NTP_UNIX;
        let frac = ((d.subsec_micros() as u64) << 32) / 1_000_000;
        let mut stamp = [0u8; 8];
        stamp[..4].copy_from_slice(&(secs as u32).to_be_bytes());
        stamp[4..].copy_from_slice(&(frac as u32).to_be_bytes());
        let mut out = [0u8; 48];
        out[0] = (got[0] & 0x38) | 4; // their version, mode 4 (server)
        out[1] = if kiss { 0 } else { 2 }; // stratum
        // The reference: for stratum 2, its own server's address.
        out[12..16].copy_from_slice(if kiss { b"DENY" } else { &[192, 0, 2, 1] });
        out[16..24].copy_from_slice(&stamp); // reference
        out[24..32].copy_from_slice(&got[40..48]); // originate: their transmit
        out[32..40].copy_from_slice(&stamp); // receive
        out[40..48].copy_from_slice(&stamp); // transmit
        socket.send_to(&out, from)?;
    }
}
