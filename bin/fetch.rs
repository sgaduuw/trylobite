//! fetch [-i] URL...: get each http://HOST[:PORT][/PATH] with HTTP/1.0
//! and write its body to standard output (the whole response, headers
//! too, with -i). A URL of - reads URLs from standard input, a line
//! each, as wget's -i - does. HOST may be a name, looked up through the
//! name server. The exit code is 0 if every status was 2xx, else 1,
//! with what went wrong on standard error (2 for no URL). In Rust, over trystd's net: a
//! TcpStream, and its resolver.
#![no_std]

use trystd::net::TcpStream;
use trystd::prelude::*;
use trystd::process::Message;

trystd::main!(run);

const USAGE: &str = "usage: fetch [-i] URL..., URL http://HOST[:PORT][/PATH] or -";

fn run() -> Result<i32, Message> {
    let mut headers = false;
    let mut urls: Vec<String> = Vec::new();
    for arg in env::args().skip(1) {
        match arg {
            "-i" if urls.is_empty() => headers = true,
            "-" => {
                for line in io::stdin().lines() {
                    let line = line?;
                    if !line.trim().is_empty() {
                        urls.push(line.trim().to_string());
                    }
                }
            }
            _ => urls.push(arg.to_string()),
        }
    }
    if urls.is_empty() {
        eprintln!("{USAGE}");
        return Ok(2);
    }
    let mut code = 0;
    for url in &urls {
        if let Err(e) = get(url, headers) {
            eprintln!("fetch: {url}: {e}");
            code = 1;
        }
    }
    Ok(code)
}

/// Get one URL and write what came: an error for a status other than
/// 2xx, or for no response at all.
fn get(url: &str, headers: bool) -> Result<(), Message> {
    let rest = url
        .strip_prefix("http://")
        .ok_or(Message::new("only http:// URLs"))?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse().map_err(|_| Message::new("not a port"))?),
        None => (authority, 80),
    };
    let mut stream = TcpStream::connect((host, port))?;
    write!(
        stream,
        "GET {path} HTTP/1.0\r\nHost: {authority}\r\nUser-Agent: trylobite-fetch\r\n\r\n"
    )?;
    let mut response = Vec::new();
    stream.read_to_end(&mut response)?;

    let end = response
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4);
    let mut out = io::stdout();
    match end {
        Some(end) if !headers => out.write_all(&response[end..])?,
        _ => out.write_all(&response)?,
    }
    out.flush()?;
    // HTTP/1.x NNN REASON
    let line = response.split(|&c| c == b'\r').next().unwrap_or(b"");
    let line = core::str::from_utf8(line).unwrap_or("");
    match line.split(' ').nth(1) {
        Some(code) if line.starts_with("HTTP/") && code.starts_with('2') => Ok(()),
        Some(_) if line.starts_with("HTTP/") => {
            Err(Message::new(&line[line.find(' ').unwrap_or(0) + 1..]))
        }
        _ => Err(Message::new("not an HTTP response")),
    }
}
