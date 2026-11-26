//! httpd [-n COUNT] [-p PORT] [PATH]: serve the filesystem over HTTP/1.0
//! on PORT (80 if not given): GET /P answers with the file P, or with a
//! directory's entries, a line each. It says the URL of PATH (/ if not
//! given) on standard output, which it then closes, so that a pipe can
//! hand it on (`httpd -n 1 notes | fetch -`), and each request on
//! standard error. It serves COUNT requests and ends, or for ever. A wrong argument
//! gives the usage and exit code 2. In
//! Rust, over trystd's net (a TcpListener) and fs.
#![no_std]

use trystd::fs::{self, File};
use trystd::net::{self, TcpListener, TcpStream};
use trystd::prelude::*;
use trystd::process::Message;

trystd::main!(run);

const USAGE: &str = "usage: httpd [-n COUNT] [-p PORT] [PATH]";

fn run() -> Result<i32, Message> {
    let Some((count, port, path)) = options() else {
        eprintln!("{USAGE}");
        return Ok(2);
    };
    let listener = TcpListener::bind((net::Ipv4Addr::UNSPECIFIED, port))?;
    let here = listener.local_addr()?;
    println!("http://{here}/{}", path.trim_start_matches('/'));
    io::stdout().flush()?;
    // Standard output is done with, so that whoever reads it sees its end.
    drop(fs::OwnedFd::from_raw(trystd::sys::STDOUT));

    let mut served = 0;
    while count.is_none_or(|n| served < n) {
        let (stream, from) = listener.accept()?;
        if let Err(e) = serve(stream, from) {
            eprintln!("httpd: {from}: {e}");
        }
        served += 1;
    }
    Ok(0)
}

/// The arguments: how many requests to serve (None for no end), the
/// port, and the path to say the URL of; None if they make no sense.
fn options() -> Option<(Option<u32>, u16, &'static str)> {
    let mut args = env::args().skip(1);
    let (mut count, mut port, mut path) = (None, 80, "/");
    while let Some(arg) = args.next() {
        match arg {
            "-n" => count = Some(args.next()?.parse().ok()?),
            "-p" => port = args.next()?.parse().ok().filter(|&p| p != 0)?,
            _ if !arg.starts_with('-') => path = arg,
            _ => return None,
        }
    }
    Some((count, port, path))
}

/// Answer one request on `stream`.
fn serve(mut stream: TcpStream, from: net::SocketAddrV4) -> io::Result<()> {
    // The request line and headers, up to the empty line.
    let mut request = Vec::new();
    let mut buf = [0u8; 243];
    while !request.windows(4).any(|w| w == b"\r\n\r\n") && !request.windows(2).any(|w| w == b"\n\n")
    {
        match stream.read(&mut buf)? {
            0 => break,
            n => request.extend_from_slice(&buf[..n]),
        }
        if request.len() > 4096 {
            break;
        }
    }
    let line = request
        .split(|&c| c == b'\r' || c == b'\n')
        .next()
        .unwrap_or(b"");
    let line = core::str::from_utf8(line).unwrap_or("");
    let mut words = line.split(' ');
    let (method, target) = (words.next().unwrap_or(""), words.next().unwrap_or(""));
    let status = if method != "GET" || !target.starts_with('/') {
        reply(&mut stream, "400 Bad Request", b"bad request\n")
    } else {
        match fs::metadata(target) {
            Ok(m) if m.is_dir() => {
                let mut list = Vec::new();
                for entry in fs::read_dir(target)? {
                    let entry = entry?;
                    let slash = if entry.metadata().is_ok_and(|m| m.is_dir()) {
                        "/"
                    } else {
                        ""
                    };
                    writeln!(list, "{}{slash}", entry.file_name())?;
                }
                reply(&mut stream, "200 OK", &list)
            }
            Ok(_) => {
                let mut body = Vec::new();
                File::open(target)?.read_to_end(&mut body)?;
                reply(&mut stream, "200 OK", &body)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                reply(&mut stream, "404 Not Found", b"not found\n")
            }
            Err(e) => return Err(e),
        }
    }?;
    eprintln!("httpd: {from} {line} {status}");
    Ok(())
}

/// Send a response with `status` and `body`: the status's code.
fn reply(stream: &mut TcpStream, status: &'static str, body: &[u8]) -> io::Result<&'static str> {
    write!(
        stream,
        "HTTP/1.0 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)?;
    Ok(&status[..3])
}
