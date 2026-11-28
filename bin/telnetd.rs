//! telnetd [-p PORT] [-n COUNT]: a remote shell. It takes TCP
//! connections on port 23, or PORT, and gives each one a shell,
//! /bin/sh, whose standard input, output and error are the connection,
//! through a pipe each way: bin/telnet, or any Telnet client, reaches the
//! machine's shell as if at the console. With -n it serves COUNT
//! connections and exits once they have ended; without, it serves for
//! ever.
//!
//! There are no users or passwords yet: whoever reaches the port has the
//! shell. So nothing starts it unasked: /etc/init has a line for it to
//! uncomment, and on `detrytus run --net user` only the host itself can
//! reach it, through `--forward 2323:23` (`telnet localhost 2323`).
//!
//! It speaks the Telnet protocol (RFC 854): it says it will ECHO and
//! SUPPRESS-GO-AHEAD, so the client sends each key as typed and the
//! shell's own echo and line editing work as at the console, answers no
//! other option, and turns CR LF and CR NUL from the client into the CR
//! the shell takes for Enter, and the shell's newlines into CR LF.
//! Ctrl-C (or the protocol's Interrupt Process) is SIGINT to what the
//! shell runs; at the prompt, where it runs nothing, it is the key that
//! drops the line. When the shell exits the connection closes, and when
//! the client goes the shell's input ends, which ends it.
//!
//! In Rust, over trystd's net, process and thread: a thread for each
//! connection carries the shell's output, and another the client's keys.
#![no_std]

extern crate alloc;

use alloc::sync::Arc;
use alloc::vec::Vec;
use trystd::fs::File;
use trystd::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream};
use trystd::os;
use trystd::prelude::*;
use trystd::process::{ChildStdin, Command, Stdio};
use trystd::sys;

trystd::main!(run);

const PORT: u16 = 23;
const CHUNK: usize = 1460;

const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;
const SB: u8 = 250;
const IP: u8 = 244; // Interrupt Process
const SE: u8 = 240;
const ECHO: u8 = 1;
const SGA: u8 = 3;
const CR: u8 = 13;
const LF: u8 = 10;
const CTRL_C: u8 = sys::CTRL_C as u8;

fn usage() -> i32 {
    Line::new().str("usage: telnetd [-p PORT] [-n COUNT]").eprint();
    2
}

fn run() -> i32 {
    let (mut port, mut count) = (PORT, None);
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args.next().and_then(|v| v.parse::<u16>().ok()).filter(|&v| v > 0);
        match (arg, value) {
            ("-p", Some(p)) => port = p,
            ("-n", Some(n)) => count = Some(n),
            _ => return usage(),
        }
    }
    let listener = match TcpListener::bind((Ipv4Addr::UNSPECIFIED, port)) {
        Ok(l) => l,
        Err(e) => {
            Line::new().str("telnetd: port ").num(port as i64).str(": ").error(&e).eprint();
            return 1;
        }
    };
    let mut sessions = Vec::new();
    let mut served = 0;
    while count.is_none_or(|n| served < n) {
        let (stream, _) = match listener.accept() {
            Ok(c) => c,
            Err(e) => {
                Line::new().str("telnetd: ").error(&e).eprint();
                return 1;
            }
        };
        served += 1;
        // Neither this shell nor the next gets the connection itself.
        let _ = stream.as_fd().set_inherit(false);
        let session = thread::spawn(move || serve(Arc::new(stream)));
        if count.is_some() {
            sessions.push(session);
        }
    }
    drop(listener);
    for session in sessions {
        let _ = session.join();
    }
    0
}

/// Give the client a shell, and carry its output until it ends.
fn serve(stream: Arc<TcpStream>) {
    let mut net = &*stream;
    let Some((mut shell, output)) = start_shell() else {
        let _ = net.write_all(b"telnetd: cannot start /bin/sh\r\n");
        let _ = stream.shutdown(Shutdown::Write);
        return;
    };
    let _ = net.write_all(&[IAC, WILL, ECHO, IAC, WILL, SGA]);
    let input = shell.stdin.take();
    let pid = shell.id();
    let keys = stream.clone();
    let typing = thread::spawn(move || {
        if let Some(input) = input {
            type_in(&keys, input, pid);
        }
    });
    // The shell's output, newlines as CR LF, until it ends.
    let mut buf = [0u8; CHUNK];
    let mut out = [0u8; 2 * CHUNK];
    let mut from = &output;
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let mut m = 0;
        for &b in &buf[..n] {
            match b {
                LF => {
                    out[m] = CR;
                    m += 1;
                }
                IAC => {
                    out[m] = IAC;
                    m += 1;
                }
                _ => {}
            }
            out[m] = b;
            m += 1;
        }
        if net.write_all(&out[..m]).is_err() {
            break;
        }
    }
    let _ = shell.wait();
    // The client closes its end once it has read ours, which ends the
    // thread reading it.
    let _ = stream.shutdown(Shutdown::Write);
    let _ = typing.join();
}

/// /bin/sh, its standard input a pipe from us and its output and error
/// one pipe to us: the shell, and that pipe's end.
fn start_shell() -> Option<(process::Child, File)> {
    let (read, write) = process::pipe().ok()?;
    let _ = read.set_inherit(false);
    let error = write.try_clone().ok()?;
    let shell = Command::new("sh")
        .stdin(Stdio::piped())
        .stdout(Stdio::from(write))
        .stderr(Stdio::from(error))
        .spawn()
        .ok()?;
    Some((shell, File::from_fd(read)))
}

/// Where the reader is in what the client sends.
#[derive(Clone, Copy)]
enum In {
    Data,
    Cr,
    Iac,
    Option(u8),
    Sub,
    SubIac,
}

/// Pass the client's keys to the shell `pid`'s input until the client
/// goes: options answered and dropped, Enter as CR, Ctrl-C an interrupt.
fn type_in(stream: &Arc<TcpStream>, mut to: ChildStdin, pid: u32) {
    let mut net = &**stream;
    let mut buf = [0u8; CHUNK];
    let mut keys = [0u8; CHUNK];
    let mut state = In::Data;
    loop {
        let n = match net.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let mut m = 0;
        for &b in &buf[..n] {
            state = match (state, b) {
                (In::Data | In::Cr, IAC) => In::Iac,
                (In::Cr, LF | 0) => In::Data, // the CR was Enter
                (_, CTRL_C) if matches!(state, In::Data | In::Cr) => {
                    if !interrupt(pid) {
                        keys[m] = CTRL_C;
                        m += 1;
                    }
                    In::Data
                }
                (In::Data | In::Cr, _) => {
                    keys[m] = b;
                    m += 1;
                    if b == CR { In::Cr } else { In::Data }
                }
                (In::Iac, IAC) => {
                    keys[m] = IAC;
                    m += 1;
                    In::Data
                }
                (In::Iac, IP) => {
                    if !interrupt(pid) {
                        keys[m] = CTRL_C;
                        m += 1;
                    }
                    In::Data
                }
                (In::Iac, WILL | WONT | DO | DONT) => In::Option(b),
                (In::Iac, SB) => In::Sub,
                (In::Iac, _) => In::Data,
                (In::Option(verb), option) => {
                    answer(&mut net, verb, option);
                    In::Data
                }
                (In::Sub, IAC) => In::SubIac,
                (In::Sub, _) => In::Sub,
                (In::SubIac, SE) => In::Data,
                (In::SubIac, _) => In::Sub,
            };
        }
        if m > 0 && to.write_all(&keys[..m]).is_err() {
            break;
        }
    }
    // Dropping the pipe ends the shell's input.
}

/// Answer the client: we do ECHO and SUPPRESS-GO-AHEAD, as we said,
/// and nothing else; it may do whatever it likes, but nothing is asked
/// of it. What agrees with what we said goes unanswered.
fn answer(net: &mut &TcpStream, verb: u8, option: u8) {
    let reply = match (verb, option) {
        (DO, ECHO | SGA) | (DONT, _) | (WILL, _) | (WONT, _) => return,
        (DO, _) => WONT,
        _ => return,
    };
    let _ = net.write_all(&[IAC, reply, option]);
}

/// Send SIGINT to what shell `pid` runs: false if it runs nothing.
fn interrupt(pid: u32) -> bool {
    let mut any = false;
    for (child, p) in os::processes() {
        if p.parent == Some(pid) {
            let _ = signal::kill(child as i32, sys::SIGINT);
            any = true;
        }
    }
    any
}
