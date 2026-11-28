//! ntpd [-n | -q] [SERVER]: keep the time of day right by asking NTP
//! servers (SNTP, RFC 4330): the addresses of pool.ntp.org, or of the
//! SERVER named, up to SOURCES of them, or the one address given.
//! /etc/init starts it: each round it asks every source, steps the clock
//! by the offset the one with the shortest round trip found, then waits
//! POLL ticks (about 17 minutes on a live machine), RETRY after a round
//! with no answer, which also looks the name up again. It tells the
//! console when it first sets the clock and when it has to step it by
//! more than STEP_LOUD. A failure it reports once it has failed QUIET
//! rounds in a row, and not again until an answer comes: a machine run
//! without a network should not have it in the middle of a session.
//!
//! While it waits it serves as "ntp" (NTP_PROTOCOL): NTP_STATUS gives
//! its state as text, which bin/ntpctl shows (docs/kernel.md, The time
//! of day, for the format).
//!
//! -q asks once, sets the clock and exits, as ntpd -q does. -n asks
//! once and prints what each source said, setting nothing; any program
//! may do that, while setting the clock is for programs init starts (the
//! kernel says "not allowed" to the rest). In Rust, over trystd's net,
//! time and sys.
#![no_std]

use core::fmt::Write as _;
use trystd::net::{self, Ipv4Addr, UdpSocket};
use trystd::prelude::*;
use trystd::process::Message;
use trystd::sys::{self, Received};
use trystd::time::{self as clock, Duration, Instant, SystemTime};

trystd::main!(run);

const USAGE: &str = "usage: ntpd [-n | -q] [SERVER]";
const SERVER: &str = "pool.ntp.org";
const PORT: u16 = 123;
const SOURCES: usize = 4; // addresses of a name to ask at most

const POLL: i64 = 1_024_000_000; // ticks between rounds: 1,024 s at a million a second,
const RETRY: i64 = 64_000_000; // and after a round with no answer, 64 s
const WAIT: u32 = 1_000_000; // ticks to wait for each answer,
const TRIES: usize = 3; // and how many times to ask
const QUIET: u32 = 3; // failed rounds in a row before one is reported
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
    if mode == Mode::Daemon {
        return daemon(server);
    }
    let mut ntp = Ntp::new(server);
    if let Err(e) = ntp.resolve() {
        eprintln!("ntpd: {server}: {e}");
        return Ok(1);
    }
    let best = ntp.round();
    for s in &ntp.sources {
        match &s.last {
            Ok(()) if mode == Mode::Show => {
                let x = s.sample();
                println!(
                "{}: offset {} s, delay {} s, stratum {}",
                ntp.name(s.ip),
                seconds(x.offset),
                seconds(x.delay),
                x.stratum
                )
            }
            Ok(()) => {}
            Err(e) => eprintln!("ntpd: {}: {e}", ntp.name(s.ip)),
        }
    }
    match best {
        None => Ok(1),
        Some(_) if mode == Mode::Show => Ok(0),
        Some(i) => match ntp.step(i) {
            Ok(()) => Ok(0),
            Err(e) => {
                eprintln!("ntpd: {e}");
                Ok(1)
            }
        },
    }
}

/// Ask, step, serve status until the next round, for ever: an exit only
/// when the clock may not be set, which asking again will not change.
fn daemon(server: &str) -> Result<i32, Message> {
    let mut ntp = Ntp::new(server);
    // Without the name (another ntpd has it) it still keeps time.
    let serving = sys::register(b"ntp\0", sys::NTP_PROTOCOL).is_ok();
    let mut failures = 0;
    loop {
        let answered = match ntp.resolve() {
            Ok(()) => ntp.round(),
            Err(e) => {
                ntp.failure = format!("{e}");
                None
            }
        };
        let wait = match answered {
            Some(i) => {
                let loud = !ntp.synced || ntp.sources[i].sample().offset.abs() >= STEP_LOUD;
                if loud {
                    ntp.step(i)?;
                } else {
                    ntp.step_quietly(i)?;
                }
                failures = 0;
                POLL
            }
            None => {
                failures += 1;
                if failures == QUIET {
                    eprintln!("ntpd: {}: {}", server, ntp.failure);
                }
                RETRY
            }
        };
        ntp.poll = wait;
        let until = sys::ticks() + wait;
        if !serving {
            sys::sleep_until(until);
            continue;
        }
        sys::alarm_until(until);
        loop {
            match sys::receive() {
                Received::Notice { note, .. } if note == sys::NOTE_ALARM => break,
                Received::Notice { .. } => {}
                Received::Call { from, words } => {
                    let r = match words {
                        [op, at, size] if op == sys::NTP_STATUS => {
                            let text = ntp.status();
                            let n = text.len().min(size.max(0) as usize);
                            match sys::copy_out(from, &text.as_bytes()[..n], at) {
                                Ok(()) => n as i32,
                                Err(e) => e.raw_os_error().unwrap_or(sys::E_FAULT),
                            }
                        }
                        _ => sys::E_INVAL,
                    };
                    let _ = sys::reply(from, r);
                }
            }
        }
    }
}

/// What one exchange with a server found.
#[derive(Clone, Copy)]
struct Sample {
    offset: i64, // µs to add to the clock
    delay: i64,  // µs there and back, less the server's time
    stratum: u8,
    refid: [u8; 4],
}

/// One address of the server, and how it has answered.
struct Source {
    ip: Ipv4Addr,
    reach: u32,     // the last 8 rounds, the newest lowest: 1 for an answer
    when: Option<Instant>, // its last answer, by the monotonic clock
    last: Result<(), Message>, // how its last round went
    good: Option<Sample>, // its last answer
    selected: bool, // its offset set the clock last
}

impl Source {
    fn sample(&self) -> &Sample {
        self.good.as_ref().expect("a source that answered")
    }
}

/// The daemon's state, which NTP_STATUS reports.
struct Ntp<'a> {
    server: &'a str,
    sources: Vec<Source>,
    synced: bool,
    stepped: Option<(Instant, i64)>, // when the clock was last stepped, and by how much (µs)
    poll: i64,
    failure: String, // why the last round failed
}

impl<'a> Ntp<'a> {
    fn new(server: &'a str) -> Ntp<'a> {
        Ntp {
            server,
            sources: Vec::new(),
            synced: false,
            stepped: None,
            poll: 0,
            failure: String::new(),
        }
    }

    /// Look the server up while no source has answered for 8 rounds:
    /// pools hand out other addresses, and the network may have come up.
    fn resolve(&mut self) -> io::Result<()> {
        if !self.sources.is_empty() && self.sources.iter().any(|s| s.reach != 0) {
            return Ok(());
        }
        let ips = match self.server.parse::<Ipv4Addr>() {
            Ok(ip) => vec![ip],
            Err(_) => net::lookup_host(self.server)?,
        };
        self.sources = ips
            .into_iter()
            .take(SOURCES)
            .map(|ip| Source {
                ip,
                reach: 0,
                when: None,
                last: Err(Message::new("not asked yet")),
                good: None,
                selected: false,
            })
            .collect();
        Ok(())
    }

    /// Ask every source once: the one to take the time from (the shortest
    /// round trip), None if none answered.
    fn round(&mut self) -> Option<usize> {
        let mut best: Option<usize> = None;
        for i in 0..self.sources.len() {
            let ip = self.sources[i].ip;
            let got = exchange(ip);
            let better = match (&got, best) {
                (Ok(x), Some(b)) => x.delay < self.sources[b].sample().delay,
                (Ok(_), None) => true,
                _ => false,
            };
            let s = &mut self.sources[i];
            s.reach = (s.reach << 1) & 0xff;
            s.selected = false;
            match got {
                Ok(sample) => {
                    s.reach |= 1;
                    s.when = Some(Instant::now());
                    s.good = Some(sample);
                    s.last = Ok(());
                }
                Err(e) => {
                    self.failure = format!("{e}");
                    s.last = Err(e);
                }
            }
            if better {
                best = Some(i);
            }
        }
        best
    }

    /// Step the clock by what source `i` found, and say so.
    fn step(&mut self, i: usize) -> Result<(), Message> {
        self.step_quietly(i)?;
        let s = &self.sources[i];
        println!("ntpd: clock stepped by {} s ({})", seconds(s.sample().offset), self.name(s.ip));
        Ok(())
    }

    fn step_quietly(&mut self, i: usize) -> Result<(), Message> {
        let offset = self.sources[i].sample().offset;
        clock::step_clock(offset).map_err(|e| Message::new(format!("setting the clock: {e}")))?;
        self.sources[i].selected = true;
        self.synced = true;
        self.stepped = Some((Instant::now(), offset));
        Ok(())
    }

    /// An address as the server's: with its name, when that was not it.
    fn name(&self, ip: Ipv4Addr) -> String {
        let ip = ip.to_string();
        if ip == self.server { ip } else { format!("{} {ip}", self.server) }
    }

    /// NTP_STATUS: a line of words for the daemon, then one per source.
    ///   server NAME POLL-TICKS SYNCED(0/1) STEPPED-AT STEP-µs
    ///   source ADDRESS STRATUM REACH WHEN OFFSET-µs DELAY-µs SELECTED REFID
    /// STEPPED-AT and WHEN are Unix seconds, 0 for never; REACH is the
    /// last 8 rounds as a number, 1 bits for answers; REFID is the
    /// server's reference, "-" when it has said none.
    fn status(&self) -> String {
        let mut out = String::new();
        // Moments are kept on the monotonic clock, which the steps do
        // not move, and told as the time of day now less how long ago.
        let today = now().div_euclid(MICROS);
        let unix = |t: Option<Instant>| t.map_or(0, |t| today - t.elapsed().as_secs() as i64);
        let (at, by) = match self.stepped {
            Some((t, by)) => (unix(Some(t)), by),
            None => (0, 0),
        };
        let _ = writeln!(out, "server {} {} {} {at} {by}", self.server, self.poll, self.synced as u8);
        for s in &self.sources {
            let (stratum, offset, delay, refid) = match &s.good {
                Some(x) => (x.stratum, x.offset, x.delay, refid(x)),
                None => (0, 0, 0, String::from("-")),
            };
            let _ = writeln!(
                out,
                "source {} {stratum} {} {} {offset} {delay} {} {refid}",
                s.ip, s.reach, unix(s.when), s.selected as u8
            );
        }
        out
    }
}

/// A server's reference: four letters for stratum 1 (a clock, such as
/// GPS), the address of its own server above.
fn refid(x: &Sample) -> String {
    let r = x.refid;
    if x.stratum == 1 {
        let text: String = r.iter().take_while(|&&c| c != 0).map(|&c| {
            if c.is_ascii_graphic() { c as char } else { '?' }
        }).collect();
        if text.is_empty() { String::from("-") } else { text }
    } else {
        Ipv4Addr::new(r[0], r[1], r[2], r[3]).to_string()
    }
}

/// Ask `ip` the time, TRIES times at most.
fn exchange(ip: Ipv4Addr) -> Result<Sample, Message> {
    let mut socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    socket.set_read_timeout_ticks(Some(WAIT))?;
    let mut got = [0u8; 68]; // 48, or 68 with a key and digest
    for _ in 0..TRIES {
        // The transmit time goes out as it is and must come back as the
        // originate time, so an old or forged answer is not taken.
        let t1 = now();
        let sent = Instant::now();
        let query = request(t1);
        socket.send_to(&query, (ip, PORT))?;
        loop {
            match socket.recv_from(&mut got) {
                Ok((n, from)) if from == net::SocketAddrV4::new(ip, PORT) => {
                    // The round trip by the monotonic clock: steady
                    // whatever happens to the time of day meanwhile.
                    let t4 = t1 + micros_of(sent.elapsed());
                    match answer(&got[..n], &query[40..48], t1, t4) {
                        Ok(Some(sample)) => return Ok(sample),
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
        offset,
        delay,
        stratum,
        refid: [p[12], p[13], p[14], p[15]],
    }))
}

/// A duration in µs.
fn micros_of(d: Duration) -> i64 {
    d.as_secs() as i64 * MICROS + d.subsec_micros() as i64
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
