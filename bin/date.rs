//! date [-u] [-d @SECONDS] [+FORMAT]: the time of day, from the
//! machine's real-time clock, in UTC (trylobite has no time zones, so
//! -u changes nothing). -d @SECONDS shows that moment instead, seconds
//! since 1970-01-01 00:00:00 UTC (at most 12 digits). FORMAT is as Unix's date and strftime:
//! %Y %y %m %d %e %j %H %M %S %s %a %b %F %T %Z %n %t %%. Without one
//! it is "%a %b %e %H:%M:%S %Z %Y", as Unix's date prints in the C
//! locale. In Rust, over trystd's time.
#![no_std]

use core::fmt::Write as _;
use trystd::prelude::*;
use trystd::time::{MONTHS, SystemTime, Utc, WEEKDAYS};

trystd::main!(run);

const DEFAULT: &str = "%a %b %e %H:%M:%S %Z %Y";

fn run() -> i32 {
    let mut format = DEFAULT;
    let mut at: Option<i64> = None;
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "-u" {
            continue;
        } else if arg == "-d" {
            match args.next().and_then(|a| a.strip_prefix('@')).and_then(seconds) {
                Some(n) => at = Some(n),
                None => return usage(),
            }
        } else if let Some(f) = arg.strip_prefix('+') {
            format = f;
        } else {
            return usage();
        }
    }
    let secs = at.unwrap_or_else(|| SystemTime::now().unix_seconds());
    println!("{}", render(format, secs));
    0
}

/// A whole number of seconds, perhaps negative: at most 12 digits, so
/// it stays within a word (str::parse::<i64> needs an overflow check
/// detrytus ll does not translate yet).
fn seconds(text: &str) -> Option<i64> {
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    if digits.is_empty() || digits.len() > 12 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n = digits.bytes().fold(0i64, |n, b| n * 10 + (b - b'0') as i64);
    Some(if negative { -n } else { n })
}

fn usage() -> i32 {
    eprintln!("usage: date [-u] [-d @SECONDS] [+FORMAT]");
    2
}

/// FORMAT with each %-conversion replaced by its part of `secs`.
fn render(format: &str, secs: i64) -> String {
    let t = Utc::from_unix(secs);
    let mut out = String::new();
    let mut chars = format.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        let _ = match chars.next() {
            Some('Y') => write!(out, "{}", t.year),
            Some('y') => write!(out, "{:02}", t.year.rem_euclid(100)),
            Some('m') => write!(out, "{:02}", t.month),
            Some('d') => write!(out, "{:02}", t.day),
            Some('e') => write!(out, "{:2}", t.day),
            Some('j') => write!(out, "{:03}", t.yday),
            Some('H') => write!(out, "{:02}", t.hour),
            Some('M') => write!(out, "{:02}", t.minute),
            Some('S') => write!(out, "{:02}", t.second),
            Some('s') => write!(out, "{secs}"),
            Some('a') => write!(out, "{}", WEEKDAYS[t.weekday as usize]),
            Some('b') => write!(out, "{}", MONTHS[t.month as usize - 1]),
            Some('F') => write!(out, "{}-{:02}-{:02}", t.year, t.month, t.day),
            Some('T') => write!(out, "{:02}:{:02}:{:02}", t.hour, t.minute, t.second),
            Some('Z') => write!(out, "UTC"),
            Some('n') => write!(out, "\n"),
            Some('t') => write!(out, "\t"),
            Some('%') => write!(out, "%"),
            // Unknown, or a lone % at the end: kept as written.
            Some(other) => write!(out, "%{other}"),
            None => write!(out, "%"),
        };
    }
    out
}
