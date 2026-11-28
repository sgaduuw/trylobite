//! ntpd [-n | -q] [SERVER]: keep the time of day right by asking an
//! NTP server (SNTP, RFC 4330), pool.ntp.org unless SERVER names
//! another, by name or address. /etc/init starts it: it sets the clock
//! at once, then asks again every POLL ticks (about 17 minutes on a live
//! machine), stepping the clock by what it finds. It tells the console
//! when it first sets the clock and when it has to step it by more than
//! STEP_LOUD; failures it reports once, until an answer comes again.
//!
//! -q sets the clock once and exits, as ntpd -q does. -n asks once and
//! prints how far off the clock is, setting nothing; any program may do
//! that, while setting the clock is for programs init starts (the
//! kernel says "not allowed" to the rest). In Rust, over trystd's net,
//! time and thread.
#![no_std]

use trystd::net::{self, Ipv4Addr, UdpSocket};
use trystd::prelude::*;
use trystd::process::Message;
use trystd::time::{self as clock, SystemTime};

trystd::main!(run);

const USAGE: &str = "usage: ntpd [-n | -q] [SERVER]";
const SERVER: &str = "pool.ntp.org";
const PORT: u16 = 123;

const POLL: u32 = 1_024_000_000; // ticks between questions: 1,024 s at a million a second,
const RETRY: u32 = 64_000_000; // and after a failure, 64 s
const WAIT: u32 = 1_000_000; // ticks to wait for each answer,
const TRIES: usize = 3; // and how many times to ask
const STEP_LOUD: i64 = 128_000; // µs: a step this large is worth a line on the console

/// Seconds from 1900-01-01, where NTP counts from, to 1970-01-01.
const NTP_UNIX: i64 = 2_208_988_800;
const MICROS: i64 = 1_000_000;

#[derive(PartialEq)]
enum Mode {
    Daemon,
    Once,
    Show,
}

fn run() -> Result<i32, Message> {
    let mut mode = Mode::Daemon;
    let mut server = SERVER;
    let mut named = false;
    for arg in env::args().skip(1) {
        match arg {
            "-q" if mode == Mode::Daemon => mode = Mode::Once,
            "-n" if mode == Mode::Daemon => mode = Mode::Show,
            _ if !named && !arg.starts_with('-') => {
                server = arg;
                named = true;
            }
            _ => {
                eprintln!("{USAGE}");
                return Ok(2);
            }
        }
    }
    let once = match mode {
        Mode::Daemon => return daemon(server),
        Mode::Show => ask(server).map(|s| {
            println!(
                "{}: offset {} s, delay {} s, stratum {}",
                source(server, s.from),
                seconds(s.offset),
                seconds(s.delay),
                s.stratum
            )
        }),
        Mode::Once => ask(server).and_then(|s| step(server, &s)),
    };
    match once {
        Ok(()) => Ok(0),
        Err(e) => {
            eprintln!("ntpd: {e}");
            Ok(1)
        }
    }
}

/// Step the clock by what `s` found, and say so.
fn step(server: &str, s: &Sample) -> Result<(), Message> {
    clock::step_clock(s.offset).map_err(|e| Message::new(format!("setting the clock: {e}")))?;
    println!("ntpd: clock stepped by {} s ({})", seconds(s.offset), source(server, s.from));
    Ok(())
}

/// The server as named, with its address when the name was not one.
fn source(server: &str, ip: Ipv4Addr) -> String {
    let ip = ip.to_string();
    if ip == server { ip } else { format!("{server} {ip}") }
}

/// Ask, step, sleep, for ever: an exit only when the clock may not be
/// set, which asking again will not change.
fn daemon(server: &str) -> Result<i32, Message> {
    let mut synced = false;
    let mut failing = false;
    loop {
        let wait = match ask(server) {
            Ok(s) if !synced || s.offset.abs() >= STEP_LOUD => {
                step(server, &s)?;
                synced = true;
                failing = false;
                POLL
            }
            Ok(s) => {
                clock::step_clock(s.offset)
                    .map_err(|e| Message::new(format!("setting the clock: {e}")))?;
                failing = false;
                POLL
            }
            Err(e) => {
                if !failing {
                    eprintln!("ntpd: {e}");
                }
                failing = true;
                RETRY
            }
        };
        trystd::thread::sleep_ticks(wait);
    }
}

/// What one exchange with a server found.
struct Sample {
    from: Ipv4Addr,
    offset: i64, // µs to add to the clock
    delay: i64,  // µs there and back, less the server's time
    stratum: u8,
}

/// Look `server` up and ask it the time, TRIES times at most; what went
/// wrong as "SERVER: why".
fn ask(server: &str) -> Result<Sample, Message> {
    exchange(server).map_err(|e| Message::new(format!("{server}: {e}")))
}

fn exchange(server: &str) -> Result<Sample, Message> {
    // The lookup takes this process's one UDP port, so it goes first.
    let ip = net::host_address(server)?;
    let mut socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    socket.set_read_timeout_ticks(Some(WAIT))?;
    let mut got = [0u8; 68]; // 48, or 68 with a key and digest
    for _ in 0..TRIES {
        // The transmit time goes out as it is and must come back as the
        // originate time, so an old or forged answer is not taken.
        let t1 = now();
        let query = request(t1);
        socket.send_to(&query, (ip, PORT))?;
        loop {
            match socket.recv_from(&mut got) {
                Ok((n, from)) if from == net::SocketAddrV4::new(ip, PORT) => {
                    let t4 = now();
                    match answer(&got[..n], &query[40..48], t1, t4) {
                        Ok(Some(sample)) => return Ok(Sample { from: ip, ..sample }),
                        Ok(None) => {} // not ours
                        Err(e) => return Err(Message::new(e)),
                    }
                }
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::TimedOut => break,
                Err(e) => return Err(e.into()),
            }
        }
    }
    Err(Message::new("no answer"))
}

/// A client request: version 4, mode 3 (client), the transmit time t1.
fn request(t1: i64) -> [u8; 48] {
    let mut packet = [0u8; 48];
    packet[0] = (4 << 3) | 3;
    packet[40..48].copy_from_slice(&timestamp(t1));
    packet
}

/// What a server's answer says, None when it does not answer `sent` (our
/// transmit timestamp), an error when it does but will not serve.
fn answer(p: &[u8], sent: &[u8], t1: i64, t4: i64) -> Result<Option<Sample>, &'static str> {
    if p.len() < 48 || p[0] & 7 != 4 || p[24..32] != *sent {
        return Ok(None);
    }
    let stratum = p[1];
    if stratum == 0 {
        return Err("the server sent a kiss of death"); // RATE, DENY: go away
    }
    if p[0] >> 6 == 3 || stratum > 15 {
        return Err("the server is not synchronised");
    }
    let t2 = micros(&p[32..40]);
    let t3 = micros(&p[40..48]);
    if p[40..48] == [0; 8] {
        return Err("the server sent no time");
    }
    let offset = ((t2 - t1) + (t3 - t4)) / 2;
    let delay = (t4 - t1) - (t3 - t2);
    Ok(Some(Sample {
        from: Ipv4Addr::UNSPECIFIED,
        offset,
        delay,
        stratum,
    }))
}

/// The time of day in µs since the Unix epoch.
fn now() -> i64 {
    let t = SystemTime::now();
    let d = match t.duration_since(clock::UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64 * MICROS + d.subsec_micros() as i64,
        Err(e) => -(e.duration().as_secs() as i64 * MICROS + e.duration().subsec_micros() as i64),
    };
    d
}

/// µs since the Unix epoch as an NTP timestamp: seconds since 1900 in 32
/// bits, then the fraction of a second in 32.
fn timestamp(us: i64) -> [u8; 8] {
    let secs = us.div_euclid(MICROS);
    let frac = ((us.rem_euclid(MICROS) as u64) << 32) / MICROS as u64;
    let mut out = [0u8; 8];
    out[..4].copy_from_slice(&((secs + NTP_UNIX) as u32).to_be_bytes());
    out[4..].copy_from_slice(&(frac as u32).to_be_bytes());
    out
}

/// An NTP timestamp as µs since the Unix epoch. Its seconds wrap in
/// 2036; one with the top bit clear is taken to be after that (RFC 4330,
/// section 3), which holds until 2104.
fn micros(t: &[u8]) -> i64 {
    let secs = u32::from_be_bytes([t[0], t[1], t[2], t[3]]) as i64;
    let frac = u32::from_be_bytes([t[4], t[5], t[6], t[7]]) as u64;
    let secs = if secs < 1 << 31 { secs + (1 << 32) } else { secs };
    (secs - NTP_UNIX) * MICROS + ((frac * MICROS as u64) >> 32) as i64
}

/// µs as seconds with a sign and six decimals: +0.004213.
fn seconds(us: i64) -> String {
    let sign = if us < 0 { '-' } else { '+' };
    let us = us.abs();
    format!("{sign}{}.{:06}", us / MICROS, us % MICROS)
}
