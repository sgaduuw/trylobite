//! telnet HOST [PORT]: talk to a TCP service, port 23 (a remote shell,
//! bin/telnetd) unless PORT says, as Unix's telnet does: what is typed
//! goes to it, what it sends is printed, until it closes the connection
//! or Ctrl-] is typed.
//!
//! It speaks the Telnet protocol's network virtual terminal (RFC 854):
//! lines go out ending CR LF, and a CR LF coming in is printed as a
//! newline. Of the options (RFC 855) it takes ECHO and SUPPRESS-GO-AHEAD
//! from the server and does none itself. A server that will ECHO, as
//! telnetd does, puts it in character mode: each key goes out as typed,
//! the server prints it, and Ctrl-C goes to the server too. Otherwise it
//! is in line mode: on the console it prints what is typed and sends a
//! line at Enter (Backspace erases), and Ctrl-C ends telnet. Standard
//! input that is not the console goes out as it comes, its newlines as
//! CR LF; at its end telnet stops sending, and waits for the server to
//! close.
//!
//! Exit with 0 once the server closes, 1 if the network fails, and 2 for
//! bad arguments or no IP server. In Rust, over trystd's net and thread:
//! one thread reads the keys, the other the connection.
#![no_std]

extern crate alloc;

use alloc::sync::Arc;
use core::sync::atomic::{AtomicBool, Ordering};
use trystd::net::{Shutdown, TcpStream};
use trystd::prelude::*;
use trystd::{console, sys, thread};

trystd::main!(run);

const PORT: u16 = 23;
const CHUNK: usize = 1460;

// The protocol's commands and the options it negotiates.
const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;
const SB: u8 = 250;
const SE: u8 = 240;
const ECHO: u8 = 1;
const SGA: u8 = 3;

const CR: u8 = 13;
const LF: u8 = 10;
const BS: u8 = 8;
const DEL: u8 = 127;
const ESCAPE: u8 = 29; // Ctrl-]

/// The server echoes: character mode.
static REMOTE_ECHO: AtomicBool = AtomicBool::new(false);

fn usage() -> i32 {
    Line::new().str("usage: telnet HOST [PORT]").eprint();
    2
}

fn run() -> i32 {
    let mut args = env::args().skip(1);
    let (Some(host), port, None) = (args.next(), args.next(), args.next()) else {
        return usage();
    };
    let port = match port {
        None => PORT,
        Some(p) => match p.parse::<u16>() {
            Ok(p) if p > 0 => p,
            _ => return usage(),
        },
    };
    if sys::IP.pid().is_err() {
        Line::new().str("telnet: no IP server").eprint();
        return 2;
    }
    let to = match net::host_address(host) {
        Ok(a) => a,
        Err(e) => {
            Line::new().str("telnet: ").str(host).str(": ").error(&e).eprint();
            return 1;
        }
    };
    let stream = match TcpStream::connect((to, port)) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            Line::new().str("telnet: ").ip(to).byte(b':').num(port as i64).str(": ").error(&e).eprint();
            return 1;
        }
    };
    let terminal = io::is_terminal(sys::STDIN);
    if terminal {
        let mut line = Line::new();
        line.str("Connected to ").ip(to).str(". Escape character is '^]'.");
        line.eprint();
    }
    let keys = stream.clone();
    let _typing = thread::spawn(move || type_in(&keys, terminal));
    let code = read_out(&stream, terminal);
    if terminal {
        let _ = console::set_foreground(None);
    }
    code
}

/// Print what the server sends, answering its options, until it closes.
fn read_out(stream: &Arc<TcpStream>, terminal: bool) -> i32 {
    let mut net = &**stream;
    let mut buf = [0u8; CHUNK];
    let mut out = [0u8; CHUNK];
    let mut state = In::Data;
    loop {
        let n = match net.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                Line::new().str("telnet: ").error(&e).eprint();
                return 1;
            }
        };
        let mut m = 0;
        for &b in &buf[..n] {
            state = match (state, b) {
                (In::Data, IAC) => In::Iac,
                (In::Data, CR) => In::Cr,
                (In::Data, _) => {
                    out[m] = b;
                    m += 1;
                    In::Data
                }
                (In::Cr, LF) => {
                    out[m] = LF;
                    m += 1;
                    In::Data
                }
                (In::Cr, 0) => {
                    out[m] = CR;
                    m += 1;
                    In::Data
                }
                (In::Cr, IAC) => {
                    out[m] = CR;
                    m += 1;
                    In::Iac
                }
                (In::Cr, _) => {
                    out[m] = CR;
                    out[m + 1] = b;
                    m += 2;
                    In::Data
                }
                (In::Iac, IAC) => {
                    out[m] = IAC;
                    m += 1;
                    In::Data
                }
                (In::Iac, WILL | WONT | DO | DONT) => In::Option(b),
                (In::Iac, SB) => In::Sub,
                (In::Iac, _) => In::Data, // a command: nothing to do
                (In::Option(verb), option) => {
                    answer(stream, verb, option, terminal);
                    In::Data
                }
                (In::Sub, IAC) => In::SubIac,
                (In::Sub, _) => In::Sub,
                (In::SubIac, SE) => In::Data,
                (In::SubIac, _) => In::Sub,
            };
        }
        if m > 0 && !write_out(&out[..m]) {
            return 1;
        }
    }
    if terminal {
        Line::new().str("Connection closed by foreign host.").eprint();
    }
    0
}

/// Where the reader is in what the server sends.
#[derive(Clone, Copy)]
enum In {
    Data,
    Cr,
    Iac,
    Option(u8),
    Sub,
    SubIac,
}

/// Answer the server's WILL, WONT, DO or DONT about `option`: take its
/// ECHO and SUPPRESS-GO-AHEAD, do nothing ourselves. Only a change is
/// answered, so that the two ends never answer each other for ever.
fn answer(stream: &Arc<TcpStream>, verb: u8, option: u8, terminal: bool) {
    let reply = match (verb, option) {
        (WILL, ECHO) => {
            if REMOTE_ECHO.swap(true, Ordering::SeqCst) {
                return;
            }
            if terminal {
                // Ctrl-C is a key for the server now.
                let _ = console::set_foreground(None);
            }
            DO
        }
        (WONT, ECHO) => {
            if !REMOTE_ECHO.swap(false, Ordering::SeqCst) {
                return;
            }
            if terminal {
                let _ = console::set_foreground(Some(process::id()));
            }
            DONT
        }
        (WILL, SGA) => DO,
        (WILL, _) => DONT,
        (DO, _) => WONT,
        _ => return, // WONT and DONT: we were not, and are not
    };
    let mut net = &**stream;
    let _ = net.write_all(&[IAC, reply, option]);
}

/// Print to standard output: false once it fails.
fn write_out(bytes: &[u8]) -> bool {
    let mut stdout = io::stdout();
    stdout.write_all(bytes).and_then(|()| stdout.flush()).is_ok()
}

/// Send what is typed: in character mode as it comes, in line mode a
/// line at a time, edited here on the console. Ctrl-] ends telnet.
fn type_in(stream: &Arc<TcpStream>, terminal: bool) {
    let mut net = &**stream;
    let mut key = [0u8; CHUNK];
    let mut line = [0u8; CHUNK];
    let mut len = 0;
    let mut send = [0u8; 2 * CHUNK + 2];
    loop {
        let n = match io::stdin().read(&mut key) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let mut m = 0;
        for &b in &key[..n] {
            if terminal && b == ESCAPE {
                let _ = console::set_foreground(None);
                write_out(b"\n");
                process::exit(0);
            }
            if REMOTE_ECHO.load(Ordering::SeqCst) || !terminal {
                // As it comes: Enter as CR LF, a lone CR as CR NUL.
                match b {
                    LF => {
                        send[m] = CR;
                        send[m + 1] = LF;
                        m += 2;
                    }
                    CR => {
                        send[m] = CR;
                        send[m + 1] = 0;
                        m += 2;
                    }
                    IAC => {
                        send[m] = IAC;
                        send[m + 1] = IAC;
                        m += 2;
                    }
                    _ => {
                        send[m] = b;
                        m += 1;
                    }
                }
                continue;
            }
            // Line mode on the console: edit here, send at Enter.
            match b {
                CR | LF => {
                    write_out(b"\n");
                    for &c in &line[..len] {
                        if c == IAC {
                            send[m] = IAC;
                            m += 1;
                        }
                        send[m] = c;
                        m += 1;
                    }
                    send[m] = CR;
                    send[m + 1] = LF;
                    if net.write_all(&send[..m + 2]).is_err() {
                        return;
                    }
                    m = 0;
                    len = 0;
                }
                BS | DEL => {
                    if len > 0 {
                        len -= 1;
                        write_out(&[BS, b' ', BS]);
                    }
                }
                _ if len < CHUNK => {
                    line[len] = b;
                    len += 1;
                    write_out(&[b]);
                }
                _ => {}
            }
        }
        if m > 0 && net.write_all(&send[..m]).is_err() {
            return;
        }
    }
    // The end of input: nothing more to send; the server says when it
    // is done.
    let _ = stream.shutdown(Shutdown::Write);
}
