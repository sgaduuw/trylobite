//! nc HOST PORT: open a TCP connection to port PORT at HOST (an address
//! a.b.c.d, or a name to resolve), send it everything standard input
//! gives, then print what comes back until the other end closes. nc -l
//! PORT: wait for one connection to port PORT and print what it sends
//! until it closes. One direction at a time, as there is no waiting on
//! two descriptors at once: a peer that answers before it has read
//! everything may wait for nc as nc waits for it.
//!
//! nc -u HOST PORT: send what standard input gives, each read as one
//! UDP datagram, and after each print what comes back within a moment.
//! nc -u -l PORT: print what each datagram to port PORT carries, until
//! killed (Ctrl-C) or output fails.
//!
//! As Unix's nc. Exit with 0, 1 if the network fails, and 2 for bad
//! arguments or no IP server.
#![no_std]

use trystd::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream, UdpSocket};
use trystd::prelude::*;
use trystd::sys;

trystd::main!(run);

/// Ticks to wait for what comes back to a datagram.
const WAIT: u32 = 200_000;
/// Octets a stream read or write moves at a time.
const CHUNK: usize = 1460;

fn usage() -> i32 {
    Line::new().str("usage: nc [-u] HOST PORT, or nc [-u] -l PORT").eprint();
    2
}

/// Say on standard error why the network failed, and give 1.
fn failed(e: io::Error) -> i32 {
    let why = match e.raw_os_error() {
        Some(sys::E_NOROUTE) => "no route there",
        Some(sys::E_TIMEDOUT) => "no answer",
        Some(sys::E_IO) => "the network is down",
        Some(sys::E_BUSY) => "the port is taken",
        Some(sys::E_REFUSED) => "connection refused",
        Some(sys::E_RESET) => "connection reset",
        _ => "failed",
    };
    Line::new().str("nc: ").str(why).eprint();
    1
}

fn run() -> i32 {
    let mut args = env::args().skip(1).peekable();
    let udp = args.next_if_eq(&"-u").is_some();
    let (Some(host), Some(port), None) = (args.next(), args.next(), args.next()) else {
        return usage();
    };
    let listening = host == "-l";
    let Some(port) = port_of(port) else {
        return usage();
    };
    if sys::IP.pid().is_err() {
        Line::new().str("nc: no IP server").eprint();
        return 2;
    }
    let mut to = Ipv4Addr::UNSPECIFIED;
    if !listening {
        match net::host_address(host) {
            Ok(a) => to = a,
            Err(e) => {
                Line::new().str("nc: ").str(host).str(": ").error(&e).eprint();
                return 1;
            }
        }
    }
    let done = match (udp, listening) {
        (true, true) => listen(port),
        (true, false) => talk(to, port),
        (false, true) => accept_one(port),
        (false, false) => connect(to, port),
    };
    match done {
        Ok(()) => 0,
        Err(Failure::Net(e)) => failed(e),
        Err(Failure::Local) => 1,
    }
}

/// Why nc stops early: the network failed (said), or standard input or
/// output did (not said: a closed pipe is no news).
enum Failure {
    Net(io::Error),
    Local,
}

impl From<io::Error> for Failure {
    fn from(e: io::Error) -> Failure {
        Failure::Net(e)
    }
}

/// Write to standard output; Ok(false) once it fails.
fn out(bytes: &[u8]) -> bool {
    let mut stdout = io::stdout();
    stdout.write_all(bytes).and_then(|()| stdout.flush()).is_ok()
}

fn listen(port: u16) -> Result<(), Failure> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port))?;
    let mut buf = [0u8; net::DATAGRAM_MAX];
    loop {
        let (n, _) = socket.recv_from(&mut buf)?;
        if !out(&buf[..n]) {
            return Ok(());
        }
    }
}

fn talk(to: Ipv4Addr, port: u16) -> Result<(), Failure> {
    let mut socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    socket.set_read_timeout_ticks(Some(WAIT))?;
    let mut send = [0u8; net::DATAGRAM_MAX];
    let mut got = [0u8; net::DATAGRAM_MAX];
    loop {
        let n = io::stdin().read(&mut send).map_err(|_| Failure::Local)?;
        if n == 0 {
            return Ok(());
        }
        socket.send_to(&send[..n], (to, port))?;
        if let Ok((m, _)) = socket.recv_from(&mut got) {
            out(&got[..m]);
        }
    }
}

/// Copy what `from` gives to standard output until its end.
fn drain(from: &mut TcpStream) -> Result<(), Failure> {
    let mut buf = [0u8; CHUNK];
    loop {
        let n = from.read(&mut buf)?;
        if n == 0 || !out(&buf[..n]) {
            return Ok(());
        }
    }
}

fn accept_one(port: u16) -> Result<(), Failure> {
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))?;
    let (mut stream, _) = listener.accept()?;
    drop(listener);
    drain(&mut stream)
}

fn connect(to: Ipv4Addr, port: u16) -> Result<(), Failure> {
    let mut stream = TcpStream::connect((to, port))?;
    let mut buf = [0u8; CHUNK];
    loop {
        let n = io::stdin().read(&mut buf).map_err(|_| Failure::Local)?;
        if n == 0 {
            break;
        }
        stream.write_all(&buf[..n])?;
    }
    stream.shutdown(Shutdown::Write)?;
    drain(&mut stream)
}

/// A port, 1 to 65535.
fn port_of(s: &str) -> Option<u16> {
    if s.is_empty() || s.len() > 5 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n = s.bytes().fold(0u32, |n, b| n * 10 + (b - b'0') as u32);
    (1..=65535).contains(&n).then_some(n as u16)
}
