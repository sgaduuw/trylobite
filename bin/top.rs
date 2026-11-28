//! top [-n COUNT]: the machine and its processes, again every PERIOD
//! ticks, as Unix's top shows them. Each screen clears the terminal
//! (ANSI: cursor home, erase all) and starts with a header in the shape
//! of GNU top's:
//!
//!   top - 01:52:07 up 00:00:42, trylobite 0.1.0, load average: 0.00, 0.01, 0.00
//!   Tasks:   9 total,   1 running,   0 ready,   8 waiting,   0 zombie
//!   %Cpu0 :   3.1 us,   1.2 sy,  95.7 id
//!   Mem   :     81 pages total,     70 free,     11 used  (19,683 trytes a page)
//!
//! The time of day is the real-time clock's, in UTC; the uptime is the
//! monotonic clock's (time::uptime), which stepping the time of day
//! does not move; the load averages are the kernel's. There
//! is a %Cpu line for each hart: its shares of the ticks since the last
//! screen run in user mode (us), in the kernel (sy) and waiting for
//! work (id). Then a line per process, with its share of the clock in
//! user mode since the last screen (CPU%; with several harts the shares
//! can add up past 100) and the ticks it has run (TIME). COUNT screens,
//! or until Ctrl-C ends it. Exit with 0, with 1 if output fails, or
//! with 2 for a bad argument.
//!
//! A screen is written by hand into one buffer, not with core::fmt or
//! String, and its arithmetic is in u32 wherever the numbers allow: a
//! 64-bit division is a helper of some 3,000 steps here, a String::push
//! some 150, and a monitor should not top its own list.
#![no_std]

use trystd::prelude::*;
use trystd::sys::{self, Words};
use trystd::time::{self, SystemTime};

trystd::main!(run);

/// Ticks between screens.
const PERIOD: i64 = 1_000_000;

const NPROC: usize = sys::NPROC as usize;
const NHART: usize = 2 * sys::HART_MAX as usize + 1;

fn run() -> i32 {
    let mut left: Option<u32> = None; // screens still to show
    let args: Vec<&str> = env::args().skip(1).collect();
    match args.as_slice() {
        [] => {}
        [n, count] if *n == "-n" => match number(count) {
            Some(c) if c > 0 => left = Some(c),
            _ => return usage(),
        },
        _ => return usage(),
    }
    let mut top = Top::new();
    let mut out = Screen::new();
    let mut due = sys::ticks();
    loop {
        top.sample();
        out.clear();
        top.render(&mut out);
        if io::stdout().write_all(out.bytes()).and_then(|_| io::stdout().flush()).is_err() {
            return 1;
        }
        if let Some(n) = left.as_mut() {
            *n -= 1;
            if *n == 0 {
                return 0;
            }
        }
        due += PERIOD;
        sys::sleep_until(due);
    }
}

/// A count in decimal digits, at most 9 of them (by hand: str::parse
/// needs an overflow check detrytus ll does not translate yet).
fn number(text: &str) -> Option<u32> {
    if text.is_empty() || text.len() > 9 || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(text.bytes().fold(0, |n, b| n * 10 + (b - b'0') as u32))
}

fn usage() -> i32 {
    eprintln!("usage: top [-n COUNT]");
    2
}

/// What a hart did with its time, as hartinfo says.
#[derive(Clone, Copy)]
struct Hart {
    time: i64,
    /// When the kernel started it; ABSENT for no hart.
    started: i64,
    user: i64,
    idle: i64,
}

/// No hart: no time is ever this.
const ABSENT: i64 = i64::MIN;

/// A process, as proc says: `state` FREE for a free slot.
#[derive(Clone, Copy)]
struct Proc {
    state: i32,
    parent: i32,
    pages: i32,
    cpu: i64,
    name: [u8; sys::PROC_NAME as usize],
}

/// A free slot: no state is ever this.
const FREE: i32 = i32::MIN;

/// The machine as two screens in a row saw it: everything a screen shows
/// is read first, then shown from here, so that the parts agree.
struct Top {
    up: u32, // seconds since the machine started
    info: Words<{ sys::SYSINFO as usize + 4 }>,
    clock: i64,
    harts: [Hart; NHART],
    was_harts: [Hart; NHART],
    procs: [Proc; NPROC],
    was_cpu: [i64; NPROC],
    time: i64,
    was_time: i64,
}

const NO_HART: Hart = Hart { time: 0, started: ABSENT, user: 0, idle: 0 };

impl Top {
    fn new() -> Top {
        let proc = Proc { state: FREE, parent: 0, pages: 0, cpu: 0, name: [0; sys::PROC_NAME as usize] };
        Top {
            info: Words::new(),
            up: 0,
            clock: 0,
            harts: [NO_HART; NHART],
            was_harts: [NO_HART; NHART],
            procs: [proc; NPROC],
            was_cpu: [0; NPROC],
            time: 0,
            was_time: 0,
        }
    }

    /// Read the kernel's numbers, keeping the last screen's.
    fn sample(&mut self) {
        sys::call(sys::SYS_INFO, &[self.info.ptr() as i32]);
        self.was_time = self.time;
        self.time = self.info.word_i64(sys::SI_TIME);
        self.clock = SystemTime::now().unix_seconds();
        self.up = small(time::uptime().as_secs() as i64);
        let hi: Words<{ sys::HARTINFO as usize + 4 }> = Words::new();
        for (k, h) in (-sys::HART_MAX..=sys::HART_MAX).enumerate() {
            self.was_harts[k] = self.harts[k];
            self.harts[k] = if sys::call(sys::SYS_HARTINFO, &[h, hi.ptr() as i32]) < 0 {
                NO_HART
            } else {
                Hart {
                    time: hi.word_i64(sys::HI_TIME),
                    started: hi.word_i64(sys::HI_STARTED),
                    user: hi.word_i64(sys::HI_USER),
                    idle: hi.word_i64(sys::HI_IDLE),
                }
            };
        }
        let pi: Words<{ sys::PROCINFO as usize + 4 }> = Words::new();
        for pid in 0..NPROC {
            let p = &mut self.procs[pid];
            self.was_cpu[pid] = if p.state == FREE { 0 } else { p.cpu };
            if sys::call(sys::SYS_PROC, &[pid as i32, pi.ptr() as i32]) < 0 {
                p.state = FREE;
                continue;
            }
            p.state = pi.word(sys::PI_STATE);
            p.parent = pi.word(sys::PI_PARENT);
            p.pages = pi.word(sys::PI_PAGES);
            p.cpu = pi.word_i64(sys::PI_CPU);
            for (k, c) in p.name.iter_mut().enumerate() {
                *c = pi.tryte(sys::PI_NAME + k as i32);
            }
        }
    }

    fn render(&self, out: &mut Screen) {
        out.text(b"\x1b[H\x1b[2J");
        self.summary(out);
        self.tasks(out);
        self.cpus(out);
        let pages = self.info.word_i64(sys::SI_PAGES);
        let free = self.info.word_i64(sys::SI_FREE);
        out.text(b"Mem   : ");
        out.num(pages, 6);
        out.text(b" pages total, ");
        out.num(free, 6);
        out.text(b" free, ");
        out.num(pages - free, 6);
        out.text(b" used  (");
        out.grouped(sys::PAGE as u32);
        out.text(b" trytes a page)\n\n  PID  PPID STATE    PAGES   CPU%       TIME NAME\n");
        let span = self.time - self.was_time;
        for (pid, p) in self.procs.iter().enumerate() {
            if p.state != FREE {
                let mut ran = p.cpu - self.was_cpu[pid];
                if ran < 0 {
                    ran = p.cpu; // a new tenant of the slot
                }
                row(out, pid as i64, p, tenths(ran, span));
            }
        }
    }

    /// top - HH:MM:SS up [D days, ]HH:MM:SS, trylobite R, load average: ...
    fn summary(&self, out: &mut Screen) {
        out.text(b"top - ");
        // The seconds into the day, without a 64-bit division: the clock
        // is high * 2^32 + low, and 2^32 is 23,296 past a whole day.
        let (high, low) = ((self.clock >> 32) as u32, self.clock as u32);
        out.clock(((high % 86_400) * 23_296 % 86_400 + low % 86_400) % 86_400);
        out.text(b" up ");
        let up = self.up;
        let days = up / 86_400;
        if days > 0 {
            out.num(days as i64, 0);
            out.text(if days == 1 { b" day, " } else { b" days, " });
        }
        out.clock(up % 86_400);
        out.text(b", trylobite ");
        let mut k = sys::SI_RELEASE;
        while k < sys::SI_RELEASE + sys::RELEASE_MAX && self.info.tryte(k) != 0 {
            out.byte(self.info.tryte(k));
            k += 1;
        }
        out.text(b", load average: ");
        for (i, at) in [sys::SI_LOAD1, sys::SI_LOAD5, sys::SI_LOAD15].into_iter().enumerate() {
            let one = sys::LOAD_ONE as u32; // a load is under 2^32 / 100 of them
            let hundredths = (small(self.info.word_i64(at)) * 100 + one / 2) / one;
            out.num((hundredths / 100) as i64, 0);
            out.byte(b'.');
            out.digits(hundredths % 100, 2);
            out.text(if i == 2 { b"\n" } else { b", " });
        }
    }

    /// Tasks: the processes by state: running, ready for a hart,
    /// waiting (for a call, a child, the clock and so on), ended.
    fn tasks(&self, out: &mut Screen) {
        let mut count = [0i64; 5]; // total, running, ready, waiting, zombie
        for p in self.procs.iter().filter(|p| p.state != FREE) {
            count[0] += 1;
            count[match p.state {
                sys::ST_RUNNING => 1,
                sys::ST_READY => 2,
                sys::ST_ZOMBIE => 4,
                _ => 3,
            }] += 1;
        }
        let words: [&[u8]; 5] = [b" total,", b" running,", b" ready,", b" waiting,", b" zombie\n"];
        out.text(b"Tasks:");
        for (n, what) in count.into_iter().zip(words) {
            out.num(n, 4);
            out.text(what);
        }
    }

    /// A line for each hart: its shares of the ticks since the last
    /// screen (or since it started) in user mode, in the kernel and idle.
    fn cpus(&self, out: &mut Screen) {
        for (k, h) in (-sys::HART_MAX..=sys::HART_MAX).enumerate() {
            let now = self.harts[k];
            if now.started == ABSENT {
                continue;
            }
            let mut was = self.was_harts[k];
            if was.started != now.started {
                was = Hart { time: now.started, started: now.started, user: 0, idle: 0 };
            }
            let ticks = now.time - was.time;
            let us = tenths(now.user - was.user, ticks);
            let id = tenths(now.idle - was.idle, ticks);
            let sy = 1000u32.saturating_sub(us + id);
            out.text(match h {
                -4 => b"%Cpu-4:",
                -3 => b"%Cpu-3:",
                -2 => b"%Cpu-2:",
                -1 => b"%Cpu-1:",
                0 => b"%Cpu0 :",
                1 => b"%Cpu1 :",
                2 => b"%Cpu2 :",
                3 => b"%Cpu3 :",
                _ => b"%Cpu4 :",
            });
            out.percent(us, 6);
            out.text(b" us,");
            out.percent(sy, 6);
            out.text(b" sy,");
            out.percent(id, 6);
            out.text(b" id\n");
        }
    }
}

/// `part` of `whole` in tenths of a percent, 0 for no whole. Both are
/// halved until a thousand wholes fit a u32, for a 32-bit division.
fn tenths(mut part: i64, mut whole: i64) -> u32 {
    if whole <= 0 || part <= 0 {
        return 0;
    }
    while whole > 4_000_000 {
        whole >>= 1;
        part >>= 1;
    }
    let part = small(part).min(100 * whole as u32); // at most 100 wholes
    part * 1000 / whole as u32
}

/// A count known to be at least 0 and under 2^32, as a u32.
fn small(n: i64) -> u32 {
    n.clamp(0, u32::MAX as i64) as u32
}

/// A process's line: PID, PPID (- for none), STATE, PAGES, CPU%, TIME
/// and NAME (- for none).
fn row(out: &mut Screen, pid: i64, p: &Proc, cpu: u32) {
    out.num(pid, 5);
    if p.parent < 0 {
        out.text(b"     -");
    } else {
        out.num(p.parent as i64, 6);
    }
    out.text(match p.state {
        sys::ST_SLEEP => b" sleep  ",
        sys::ST_LOOKUP => b" lookup ",
        sys::ST_RECEIVE => b" receive",
        sys::ST_REPLY => b" reply  ",
        sys::ST_CALL => b" call   ",
        sys::ST_ZOMBIE => b" zombie ",
        sys::ST_WAIT => b" wait   ",
        sys::ST_RECV => b" recv   ",
        sys::ST_READY => b" ready  ",
        sys::ST_RUNNING => b" run    ",
        _ => b" ?      ",
    });
    out.num(p.pages as i64, 6);
    out.percent(cpu, 7);
    out.num(p.cpu, 11);
    out.byte(b' ');
    match p.name.iter().position(|&c| c == 0) {
        Some(0) => out.byte(b'-'),
        Some(n) => out.text(&p.name[..n]),
        None => out.text(&p.name),
    }
    out.byte(b'\n');
}

/// `n` in exactly `to.len()` decimal digits.
fn put(to: &mut [u8], mut n: u32) {
    for d in to.iter_mut().rev() {
        *d = b'0' + (n % 10) as u8;
        n /= 10;
    }
}

/// Room for one screen: a header with a line for each hart and NPROC
/// lines of processes fit with room to spare. What would run past the
/// end is dropped.
const SCREEN: usize = 4096;

struct Screen {
    buf: [u8; SCREEN],
    len: usize,
}

impl Screen {
    fn new() -> Screen {
        Screen { buf: [0; SCREEN], len: 0 }
    }

    fn clear(&mut self) {
        self.len = 0;
    }

    fn bytes(&self) -> &[u8] {
        &self.buf[..self.len]
    }

    fn byte(&mut self, b: u8) {
        self.text(&[b]);
    }

    /// The length is read and written once, not for each byte: a u32 in
    /// memory is four trytes, and loading or storing one is a helper call.
    fn text(&mut self, s: &[u8]) {
        let len = self.len;
        let n = s.len().min(SCREEN - len);
        self.buf[len..len + n].copy_from_slice(&s[..n]);
        self.len = len + n;
    }

    /// `n` in decimal, right-aligned in `width` columns. A number that
    /// fits a u32 is divided as one: a 64-bit division is a helper call.
    fn num(&mut self, n: i64, width: usize) {
        let mut digits = [0u8; 24]; // a sign, 20 digits, padding to 11 columns
        let mut k = digits.len();
        let mut m = n.unsigned_abs();
        while m > u32::MAX as u64 {
            k -= 1;
            digits[k] = b'0' + (m % 10) as u8;
            m /= 10;
        }
        let mut m = m as u32;
        loop {
            k -= 1;
            digits[k] = b'0' + (m % 10) as u8;
            m /= 10;
            if m == 0 {
                break;
            }
        }
        if n < 0 {
            k -= 1;
            digits[k] = b'-';
        }
        while digits.len() - k < width {
            k -= 1;
            digits[k] = b' ';
        }
        self.text(&digits[k..]);
    }

    /// `n`, 0 to 10^width - 1, in exactly `width` digits (at most 3).
    fn digits(&mut self, n: u32, width: usize) {
        let mut d = [0u8; 3];
        put(&mut d[..width], n);
        self.text(&d[..width]);
    }

    /// Seconds within a day as HH:MM:SS.
    fn clock(&mut self, s: u32) {
        let mut t = [b':'; 8];
        put(&mut t[0..2], s / 3600);
        put(&mut t[3..5], s % 3600 / 60);
        put(&mut t[6..8], s % 60);
        self.text(&t);
    }

    /// Tenths of a percent as a percentage in `width` columns: " 95.7".
    fn percent(&mut self, tenths: u32, width: usize) {
        self.num((tenths / 10) as i64, width - 2);
        self.byte(b'.');
        self.digits(tenths % 10, 1);
    }

    /// A number with commas between its thousands: 19,683.
    fn grouped(&mut self, n: u32) {
        if n >= 1000 {
            self.grouped(n / 1000);
            self.byte(b',');
            self.digits(n % 1000, 3);
        } else {
            self.num(n as i64, 0);
        }
    }
}
