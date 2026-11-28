//! ntpctl [-s status|sources|all]: show what bin/ntpd knows, as
//! OpenNTPD's ntpctl and ntpq -p do: whether the clock is set, from
//! which server, when it was last stepped and by how much, and for each
//! source its address, its own reference, stratum, when it last
//! answered, how often ntpd asks, which of the last 8 rounds it answered
//! (reach, in octal as ntpq shows it), the round trip and its offset.
//! The source the clock was last set from is marked *, and one that has
//! not answered for a round is marked ?. Without -s it shows all. It asks
//! ntpd over IPC (NTP_STATUS), so ntpd must be running: exit 1 if not.
//! In Rust, over trystd's sys.
#![no_std]

use trystd::prelude::*;
use trystd::sys::{self, Server};
use trystd::time::SystemTime;

trystd::main!(run);

const USAGE: &str = "usage: ntpctl [-s status|sources|all]";
static NTP: Server = Server::new(b"ntp\0", sys::NTP_PROTOCOL);

fn run() -> i32 {
    let args: Vec<&str> = env::args().skip(1).collect();
    let (status, sources) = match args.as_slice() {
        [] => (true, true),
        ["-s", "status"] => (true, false),
        ["-s", "sources" | "peers"] => (false, true),
        ["-s", "all"] => (true, true),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let mut buf = vec![0u8; 4096];
    let n = match NTP.call(sys::NTP_STATUS, &[buf.as_mut_ptr() as i32, buf.len() as i32]) {
        Ok(n) => n as usize,
        Err(_) => {
            eprintln!("ntpctl: ntpd is not running");
            return 1;
        }
    };
    let text = core::str::from_utf8(&buf[..n]).unwrap_or("");
    let now = SystemTime::now().unix_seconds();
    let mut out = String::new();
    let mut rows = Vec::new();
    let mut header: Option<Vec<&str>> = None;
    for line in text.lines() {
        let words: Vec<&str> = line.split(' ').collect();
        match words.first() {
            Some(&"server") if words.len() == 6 => header = Some(words),
            Some(&"source") if words.len() == 9 => rows.push(words),
            _ => {}
        }
    }
    let Some(h) = header else {
        eprintln!("ntpctl: ntpd's answer made no sense");
        return 1;
    };
    let poll = number(h[2]) / 1_000_000; // ticks, about a million a second
    if status {
        let answering = rows.iter().filter(|r| number(r[3]) & 1 == 1).count();
        out += &format!(
            "{}/{} sources answering, clock {}",
            answering,
            rows.len(),
            if h[3] == "1" { "synced" } else { "unsynced" }
        );
        if let Some(r) = rows.iter().find(|r| r[7] == "1") {
            out += &format!(" to {}", r[1]);
        }
        let at = number(h[4]);
        if at != 0 {
            out += &format!(", stepped {} s {} ago", seconds(number(h[5])), ago(now - at));
        }
        out += &format!("\n{} asks every {} s\n", h[1], poll);
    }
    if sources {
        if status {
            out.push('\n');
        }
        out += "  remote           refid            st  when  poll reach    delay ms   offset ms\n";
        for r in &rows {
            let mark = if r[7] == "1" {
                '*'
            } else if number(r[3]) & 1 == 0 {
                '?'
            } else {
                ' '
            };
            let when = number(r[4]);
            let answered = when != 0;
            out += &format!(
                "{mark} {:<16} {:<16} {:>2} {:>5} {:>5}   {:03o} {:>11} {:>11}\n",
                r[1],
                r[8],
                if answered { r[2] } else { "-" },
                if answered { ago(now - when) } else { String::from("-") },
                poll,
                number(r[3]),
                if answered { millis(number(r[6]), false) } else { String::from("-") },
                if answered { millis(number(r[5]), true) } else { String::from("-") },
            );
        }
    }
    print!("{out}");
    0
}

/// A whole number, perhaps negative; 0 for anything else. By hand, as
/// str::parse::<i64> needs an overflow check detrytus ll lacks.
fn number(text: &str) -> i64 {
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    if digits.is_empty() || digits.len() > 15 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return 0;
    }
    let n = digits.bytes().fold(0i64, |n, b| n * 10 + (b - b'0') as i64);
    if negative { -n } else { n }
}

/// How long ago, in the largest unit that fits, as ntpq: 42s, 17m, 3h, 2d.
fn ago(secs: i64) -> String {
    let secs = secs.max(0);
    match secs {
        0..120 => format!("{secs}s"),
        120..7200 => format!("{}m", secs / 60),
        7200..172_800 => format!("{}h", secs / 3600),
        _ => format!("{}d", secs / 86_400),
    }
}

/// µs as milliseconds with three decimals, signed when asked.
fn millis(us: i64, signed: bool) -> String {
    let sign = if us < 0 { "-" } else if signed { "+" } else { "" };
    let us = us.abs();
    format!("{sign}{}.{:03}", us / 1000, us % 1000)
}

/// µs as seconds with six decimals and a sign: +0.004213.
fn seconds(us: i64) -> String {
    let sign = if us < 0 { '-' } else { '+' };
    let us = us.abs();
    format!("{sign}{}.{:06}", us / 1_000_000, us % 1_000_000)
}
