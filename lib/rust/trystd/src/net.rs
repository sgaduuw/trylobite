//! Sockets, from the IP server (docs/kernel.md, Packets), as std::net
//! has them, for IPv4: `TcpStream`, `TcpListener`, `UdpSocket`, and a
//! stub resolver, `lookup_host`, which asks the IP server's name server
//! over UDP as lib/dns.tc does.
//!
//! The IP server gives each process one UDP port and one TCP port to
//! listen on, so a second `UdpSocket` (or a lookup, which needs a UDP
//! port) takes the port in place of the first's, and likewise a second
//! `TcpListener`. Connections have no such limit, past the descriptors.

use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;
use core::str::FromStr;

use crate::fs::OwnedFd;
use crate::io::{self, ErrorKind, Read, Write};
use crate::sys::{self, IP};

/// An IPv4 address.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Ipv4Addr(u32);

impl Ipv4Addr {
    pub const UNSPECIFIED: Ipv4Addr = Ipv4Addr(0);
    pub const LOCALHOST: Ipv4Addr = Ipv4Addr::new(127, 0, 0, 1);

    pub const fn new(a: u8, b: u8, c: u8, d: u8) -> Ipv4Addr {
        Ipv4Addr(u32::from_be_bytes([a, b, c, d]))
    }

    pub const fn octets(&self) -> [u8; 4] {
        self.0.to_be_bytes()
    }

    pub const fn to_bits(self) -> u32 {
        self.0
    }

    pub const fn from_bits(bits: u32) -> Ipv4Addr {
        Ipv4Addr(bits)
    }

    pub const fn is_unspecified(&self) -> bool {
        self.0 == 0
    }
}

impl fmt::Display for Ipv4Addr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let [a, b, c, d] = self.octets();
        write!(f, "{a}.{b}.{c}.{d}")
    }
}

/// A string that is not an address, or not an address and port.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AddrParseError;

impl fmt::Display for AddrParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid IP address syntax")
    }
}

impl FromStr for Ipv4Addr {
    type Err = AddrParseError;

    /// a.b.c.d, each 0 to 255 in decimal.
    fn from_str(s: &str) -> Result<Ipv4Addr, AddrParseError> {
        let mut octets = [0u8; 4];
        let mut parts = s.split('.');
        for octet in &mut octets {
            let part = parts.next().ok_or(AddrParseError)?;
            if part.is_empty() || part.len() > 3 || !part.bytes().all(|c| c.is_ascii_digit()) {
                return Err(AddrParseError);
            }
            *octet = part.parse().map_err(|_| AddrParseError)?;
        }
        if parts.next().is_some() {
            return Err(AddrParseError);
        }
        Ok(Ipv4Addr(u32::from_be_bytes(octets)))
    }
}

/// An IPv4 address and a port.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct SocketAddrV4 {
    ip: Ipv4Addr,
    port: u16,
}

pub type SocketAddr = SocketAddrV4;

impl SocketAddrV4 {
    pub const fn new(ip: Ipv4Addr, port: u16) -> SocketAddrV4 {
        SocketAddrV4 { ip, port }
    }

    pub const fn ip(&self) -> &Ipv4Addr {
        &self.ip
    }

    pub const fn port(&self) -> u16 {
        self.port
    }
}

impl fmt::Display for SocketAddrV4 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.ip, self.port)
    }
}

impl FromStr for SocketAddrV4 {
    type Err = AddrParseError;

    fn from_str(s: &str) -> Result<SocketAddrV4, AddrParseError> {
        let (ip, port) = s.rsplit_once(':').ok_or(AddrParseError)?;
        Ok(SocketAddrV4 {
            ip: ip.parse()?,
            port: port.parse().map_err(|_| AddrParseError)?,
        })
    }
}

/// What names a socket address: one, an address and a port, or a host
/// name and a port (`("example.org", 80)`, `"example.org:80"`), the
/// name looked up. Unlike std's it gives one address, a name's first.
pub trait ToSocketAddrs {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4>;
}

impl ToSocketAddrs for SocketAddrV4 {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4> {
        Ok(*self)
    }
}

impl ToSocketAddrs for (Ipv4Addr, u16) {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4> {
        Ok(SocketAddrV4::new(self.0, self.1))
    }
}

impl ToSocketAddrs for (&str, u16) {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4> {
        Ok(SocketAddrV4::new(host_address(self.0)?, self.1))
    }
}

impl ToSocketAddrs for str {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4> {
        let (host, port) = self.rsplit_once(':').ok_or(BAD_ADDRESS)?;
        let port = port.parse().map_err(|_| BAD_ADDRESS)?;
        (host, port).to_socket_addr()
    }
}

impl ToSocketAddrs for String {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4> {
        self.as_str().to_socket_addr()
    }
}

impl<T: ToSocketAddrs + ?Sized> ToSocketAddrs for &T {
    fn to_socket_addr(&self) -> io::Result<SocketAddrV4> {
        (**self).to_socket_addr()
    }
}

const BAD_ADDRESS: io::Error = io::Error::new(ErrorKind::InvalidInput, "invalid socket address");

/// Which way to shut a connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shutdown {
    /// Nothing changes: the IP server cannot refuse what comes.
    Read,
    /// No more writing: the other end reads its end.
    Write,
    Both,
}

/// A TCP connection.
#[derive(Debug)]
pub struct TcpStream {
    fd: OwnedFd,
    peer: SocketAddrV4,
}

impl TcpStream {
    /// Open a connection (IP_CONNECT), waiting for the handshake.
    pub fn connect<A: ToSocketAddrs>(addr: A) -> io::Result<TcpStream> {
        let peer = addr.to_socket_addr()?;
        let fd = IP.callu(sys::IP_CONNECT, &[peer.ip.0, peer.port as u32])?;
        Ok(TcpStream {
            fd: OwnedFd::from_raw(fd),
            peer,
        })
    }

    pub fn peer_addr(&self) -> io::Result<SocketAddrV4> {
        Ok(self.peer)
    }

    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        match how {
            Shutdown::Read => Ok(()),
            Shutdown::Write | Shutdown::Both => self.fd.iocall(sys::IO_SHUTDOWN, 0, 0).map(|_| ()),
        }
    }

    pub fn as_fd(&self) -> &OwnedFd {
        &self.fd
    }

    pub fn into_fd(self) -> OwnedFd {
        self.fd
    }
}

impl Read for TcpStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.fd.read(buf)
    }
}

impl Write for TcpStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.fd.write(buf)
    }
}

impl Read for &TcpStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.fd.read(buf)
    }
}

impl Write for &TcpStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.fd.write(buf)
    }
}

/// Taking TCP connections on a port. Dropping it stops.
#[derive(Debug)]
pub struct TcpListener {
    port: u16,
}

impl TcpListener {
    /// Listen on the port of `addr` (IP_LISTEN), in place of any port
    /// this process listened on. Its address part is ignored: the
    /// machine has one.
    pub fn bind<A: ToSocketAddrs>(addr: A) -> io::Result<TcpListener> {
        let port = addr.to_socket_addr()?.port;
        if port == 0 {
            return Err(io::Error::from_raw(sys::E_INVAL));
        }
        IP.call(sys::IP_LISTEN, &[port as i32])?;
        Ok(TcpListener { port })
    }

    /// Wait for a connection (IP_ACCEPT): it and where it comes from.
    pub fn accept(&self) -> io::Result<(TcpStream, SocketAddrV4)> {
        let fd = IP.call(sys::IP_ACCEPT, &[])?;
        let peer = SocketAddrV4::new(Ipv4Addr(sys::more(0) as u32), sys::more(1) as u16);
        Ok((
            TcpStream {
                fd: OwnedFd::from_raw(fd),
                peer,
            },
            peer,
        ))
    }

    /// The connections as they come.
    pub fn incoming(&self) -> Incoming<'_> {
        Incoming { listener: self }
    }

    pub fn local_addr(&self) -> io::Result<SocketAddrV4> {
        Ok(SocketAddrV4::new(local_address()?, self.port))
    }
}

impl Drop for TcpListener {
    fn drop(&mut self) {
        let _ = IP.call(sys::IP_LISTEN, &[0]);
    }
}

pub struct Incoming<'a> {
    listener: &'a TcpListener,
}

impl Iterator for Incoming<'_> {
    type Item = io::Result<TcpStream>;

    fn next(&mut self) -> Option<io::Result<TcpStream>> {
        Some(self.listener.accept().map(|(stream, _)| stream))
    }
}

/// The most data a datagram carries.
pub const DATAGRAM_MAX: usize = 1472;
/// A datagram as the IP server takes it: the address and port first.
const HEADER: usize = 6;

/// A UDP port of this process's.
#[derive(Debug)]
pub struct UdpSocket {
    port: u16,
    timeout: i32,
}

impl UdpSocket {
    /// Take the port of `addr` (IP_BIND), or a free one with port 0, in
    /// place of any UDP port this process had.
    pub fn bind<A: ToSocketAddrs>(addr: A) -> io::Result<UdpSocket> {
        let port = IP.call(sys::IP_BIND, &[addr.to_socket_addr()?.port as i32])?;
        Ok(UdpSocket {
            port: port as u16,
            timeout: 0,
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddrV4> {
        Ok(SocketAddrV4::new(local_address()?, self.port))
    }

    /// Wait at most this many ticks in `recv_from` (TimedOut after), or
    /// for ever with None. std's takes a Duration; the machine counts
    /// time in ticks of its time CSR.
    pub fn set_read_timeout_ticks(&mut self, ticks: Option<u32>) -> io::Result<()> {
        self.timeout = match ticks {
            None => 0,
            Some(0) => return Err(io::Error::from_raw(sys::E_INVAL)),
            Some(t) => i32::try_from(t).map_err(|_| io::Error::from_raw(sys::E_INVAL))?,
        };
        Ok(())
    }

    /// Send `buf` (at most DATAGRAM_MAX bytes) to `addr`: how many bytes.
    pub fn send_to<A: ToSocketAddrs>(&self, buf: &[u8], addr: A) -> io::Result<usize> {
        let to = addr.to_socket_addr()?;
        if buf.len() > DATAGRAM_MAX {
            return Err(io::Error::from_raw(sys::E_INVAL));
        }
        let mut out = [0u8; HEADER + DATAGRAM_MAX];
        out[..4].copy_from_slice(&to.ip.octets());
        out[4..6].copy_from_slice(&to.port.to_be_bytes());
        out[HEADER..HEADER + buf.len()].copy_from_slice(buf);
        IP.call(
            sys::IP_SEND,
            &[out.as_ptr() as i32, (HEADER + buf.len()) as i32],
        )?;
        Ok(buf.len())
    }

    /// The next datagram to this port, into `buf`: how many bytes, and
    /// where it came from. One longer than `buf` is cut short.
    pub fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddrV4)> {
        let mut got = [0u8; HEADER + DATAGRAM_MAX];
        let n = IP.call(
            sys::IP_RECEIVE,
            &[got.as_mut_ptr() as i32, got.len() as i32, self.timeout],
        )? as usize;
        if n < HEADER {
            return Err(io::Error::from_raw(sys::E_IO));
        }
        let from = SocketAddrV4::new(
            Ipv4Addr(u32::from_be_bytes([got[0], got[1], got[2], got[3]])),
            u16::from_be_bytes([got[4], got[5]]),
        );
        let len = (n - HEADER).min(buf.len());
        buf[..len].copy_from_slice(&got[HEADER..HEADER + len]);
        Ok((len, from))
    }
}

/// The machine's own address (IP_ADDRESS).
pub fn local_address() -> io::Result<Ipv4Addr> {
    IP.call(sys::IP_ADDRESS, &[])?;
    Ok(Ipv4Addr(sys::more(0) as u32))
}

// --- names ----------------------------------------------------------------------

const DNS_PORT: u16 = 53;
const DNS_WAIT: u32 = 200_000; // ticks to wait for each answer,
const DNS_TRIES: usize = 3; // and how many times to ask
const DNS_MAX: usize = 512; // octets DNS over UDP carries

const NO_SUCH_HOST: io::Error = io::Error::new(ErrorKind::NotFound, "no such host");
const NO_ANSWER: io::Error = io::Error::new(ErrorKind::TimedOut, "the name server did not answer");
const NO_SERVER: io::Error = io::Error::new(ErrorKind::HostUnreachable, "no name server");
const NOT_A_NAME: io::Error = io::Error::new(ErrorKind::InvalidInput, "not a host name");
const SERVER_FAILED: io::Error = io::Error::new(ErrorKind::Other, "the name server failed");

/// The address `host` gives: a.b.c.d as it stands, else the first
/// address of the name. Digits and dots alone that make no address are
/// no name either: no top-level domain is a number.
pub fn host_address(host: &str) -> io::Result<Ipv4Addr> {
    if let Ok(ip) = host.parse() {
        return Ok(ip);
    }
    if host.bytes().all(|c| c.is_ascii_digit() || c == b'.') {
        return Err(NOT_A_NAME);
    }
    Ok(lookup_host(host)?[0])
}

/// The name server resolvers ask (IP_NAMESERVER), None if there is none.
pub fn nameserver() -> io::Result<Option<Ipv4Addr>> {
    let pid = IP.pid()?;
    let r = sys::call(sys::SYS_CALL, &[pid, sys::IP_NAMESERVER, sys::NS_KEEP]);
    // An address of 2^31 or more comes back below 0 as an i32; only the
    // few numbers just below 0 are errors.
    if (sys::E_RESET..0).contains(&r) {
        return Err(io::Error::from_raw(r));
    }
    Ok((r != 0).then_some(Ipv4Addr(r as u32)))
}

/// The IPv4 addresses of `name`, from the IP server's name server: at
/// least one. NotFound if it has none.
pub fn lookup_host(name: &str) -> io::Result<Vec<Ipv4Addr>> {
    let server = nameserver()?.ok_or(NO_SERVER)?;
    lookup_host_at(name, server)
}

/// The same, asking the name server at `server`.
pub fn lookup_host_at(name: &str, server: Ipv4Addr) -> io::Result<Vec<Ipv4Addr>> {
    let mut socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    let query = dns_query(name, socket.port)?;
    socket.set_read_timeout_ticks(Some(DNS_WAIT))?;
    let mut got = [0u8; DNS_MAX];
    for _ in 0..DNS_TRIES {
        socket.send_to(&query, (server, DNS_PORT))?;
        loop {
            match socket.recv_from(&mut got) {
                Ok((n, from)) if from == SocketAddrV4::new(server, DNS_PORT) => {
                    if let Some(answer) = dns_answer(&query, &got[..n]) {
                        return answer;
                    }
                }
                Ok(_) => {}
                Err(e) if e.kind() == ErrorKind::TimedOut => break,
                Err(e) if e.raw_os_error() == Some(sys::E_NOROOM) => {}
                Err(e) => return Err(e),
            }
        }
    }
    Err(NO_ANSWER)
}

/// A query for `name`'s A records, recursion desired, numbered `id`.
fn dns_query(name: &str, id: u16) -> io::Result<Vec<u8>> {
    let name = name.strip_suffix('.').unwrap_or(name);
    if name.is_empty() || name.len() > 253 {
        return Err(NOT_A_NAME);
    }
    let mut q = Vec::with_capacity(18 + name.len());
    q.extend_from_slice(&id.to_be_bytes());
    q.extend_from_slice(&[1, 0, 0, 1, 0, 0, 0, 0, 0, 0]); // one question
    for label in name.split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err(NOT_A_NAME);
        }
        q.push(label.len() as u8);
        q.extend_from_slice(label.as_bytes());
    }
    q.extend_from_slice(&[0, 0, 1, 0, 1]); // the root, type A, class IN
    Ok(q)
}

/// What the message `m` says to `query`: None if it answers something
/// else.
fn dns_answer(query: &[u8], m: &[u8]) -> Option<io::Result<Vec<Ipv4Addr>>> {
    let octets = |i: usize| u16::from_be_bytes([m[i], m[i + 1]]) as usize;
    if m.len() < 12 || m[..2] != query[..2] || m[2] < 128 {
        return None;
    }
    Some((|| {
        match m[3] % 16 {
            0 => {}
            3 => return Err(NO_SUCH_HOST),
            _ => return Err(SERVER_FAILED),
        }
        // Where the name at i ends: labels up to an empty one, or up to a
        // pointer to the rest of it elsewhere.
        let skip = |mut i: usize| -> io::Result<usize> {
            while i < m.len() {
                match m[i] {
                    0 => return Ok(i + 1),
                    192.. => return Ok(i + 2),
                    64.. => break,
                    len => i += 1 + len as usize,
                }
            }
            Err(SERVER_FAILED)
        };
        let mut i = 12;
        for _ in 0..octets(4) {
            i = skip(i)? + 4; // its type and class
        }
        let mut found = Vec::new();
        for _ in 0..octets(6) {
            i = skip(i)?;
            if i + 10 > m.len() {
                return Err(SERVER_FAILED);
            }
            let (kind, class, len) = (octets(i), octets(i + 2), octets(i + 8));
            i += 10;
            if i + len > m.len() {
                return Err(SERVER_FAILED);
            }
            if kind == 1 && class == 1 && len == 4 {
                found.push(Ipv4Addr(u32::from_be_bytes([
                    m[i],
                    m[i + 1],
                    m[i + 2],
                    m[i + 3],
                ])));
            }
            i += len;
        }
        if found.is_empty() {
            Err(NO_SUCH_HOST)
        } else {
            Ok(found)
        }
    })())
}
