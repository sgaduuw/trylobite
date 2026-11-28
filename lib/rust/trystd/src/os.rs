//! The machine and its processes, as the kernel reports them: what a
//! platform's `std::os` module adds to std, here for the system tools
//! (bin/ps, bin/free, bin/uptime, bin/uname, bin/dmesg, bin/top).
//!
//! The kernel only reports (`SYS_INFO`, `SYS_PROC`, `SYS_HARTINFO`,
//! `SYS_LOG`); these types read its words and leave the formatting to
//! the program. Times are ticks of the time CSR, one per step of the
//! machine (detrytus platform.md, Time), except `booted`, which is Unix
//! seconds.

use alloc::vec::Vec;

use crate::io;
use crate::sys::{self, Words};

/// What `info` reports about the machine as a whole (SYS_INFO).
pub struct SysInfo {
    words: Words<{ sys::SYSINFO as usize + 4 }>,
}

/// The machine as it is now.
pub fn info() -> SysInfo {
    let words = Words::new();
    // info fails only for a bad buffer, and this one is good.
    sys::call(sys::SYS_INFO, &[words.ptr() as i32]);
    SysInfo { words }
}

impl SysInfo {
    /// The time CSR when the kernel read the rest: ticks since boot.
    pub fn time(&self) -> i64 {
        self.words.word_i64(sys::SI_TIME)
    }

    /// Timer interrupts taken since boot.
    pub fn timer_interrupts(&self) -> i64 {
        self.words.word_i64(sys::SI_TICKS)
    }

    /// Pages of memory the kernel uses.
    pub fn pages(&self) -> i32 {
        self.words.word(sys::SI_PAGES)
    }

    /// Pages of them free.
    pub fn free_pages(&self) -> i32 {
        self.words.word(sys::SI_FREE)
    }

    /// Slots in the process table.
    pub fn slots(&self) -> i32 {
        self.words.word(sys::SI_NPROC)
    }

    /// Slots in use, zombies and threads included.
    pub fn processes(&self) -> i32 {
        self.words.word(sys::SI_PROCS)
    }

    /// Harts present.
    pub fn harts(&self) -> i32 {
        self.words.word(sys::SI_HARTS)
    }

    /// The kernel's version, such as "0.1.0".
    pub fn release(&self) -> &str {
        let bytes = self.words.trytes(sys::SI_RELEASE, sys::RELEASE_MAX as usize);
        let n = bytes.iter().position(|&c| c == 0).unwrap_or(bytes.len());
        core::str::from_utf8(&bytes[..n]).unwrap_or("?")
    }

    /// The time of day at boot, in Unix seconds.
    pub fn booted(&self) -> i64 {
        self.words.word_i64(sys::SI_BOOTED)
    }

    /// The load averages over 1, 5 and 15 minutes' worth of ticks, in
    /// `sys::LOAD_ONE` parts of a process.
    pub fn load(&self) -> [i64; 3] {
        [sys::SI_LOAD1, sys::SI_LOAD5, sys::SI_LOAD15].map(|at| self.words.word_i64(at))
    }
}

/// What a process is doing, as `ProcInfo::state` reports it (the
/// kernel's ST_ values).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// On a hart, or in the kernel for it.
    Running,
    /// Waiting for a hart.
    Ready,
    /// In SYS_SLEEP, until a time.
    Sleep,
    /// In SYS_LOOKUP, for a server to register.
    Lookup,
    /// A server in SYS_RECEIVE, waiting for a call.
    Receive,
    /// Its call was received: waiting for the reply.
    Reply,
    /// Its call waits for the server to receive it.
    Call,
    /// In SYS_RECV, for a message.
    Recv,
    /// In SYS_WAIT, for a child.
    Wait,
    /// A thread waiting on a futex.
    Futex,
    /// A thread in SYS_JOIN, for another.
    Join,
    /// Ended, waiting for its last thread to go.
    Dying,
    /// Ended, until its parent waits.
    Zombie,
    /// Stopped by a signal, until SIGCONT.
    Stopped,
    /// A state this library does not know.
    Other(i32),
}

impl State {
    pub fn from_raw(st: i32) -> State {
        match st {
            sys::ST_RUNNING => State::Running,
            sys::ST_READY => State::Ready,
            sys::ST_SLEEP => State::Sleep,
            sys::ST_LOOKUP => State::Lookup,
            sys::ST_RECEIVE => State::Receive,
            sys::ST_REPLY => State::Reply,
            sys::ST_CALL => State::Call,
            sys::ST_RECV => State::Recv,
            sys::ST_WAIT => State::Wait,
            sys::ST_FUTEX => State::Futex,
            sys::ST_JOIN => State::Join,
            sys::ST_DYING => State::Dying,
            sys::ST_ZOMBIE => State::Zombie,
            sys::ST_STOPPED => State::Stopped,
            other => State::Other(other),
        }
    }

    /// The name ps and top show: at most seven letters.
    pub fn name(&self) -> &'static str {
        match self {
            State::Running => "run",
            State::Ready => "ready",
            State::Sleep => "sleep",
            State::Lookup => "lookup",
            State::Receive => "receive",
            State::Reply => "reply",
            State::Call => "call",
            State::Recv => "recv",
            State::Wait => "wait",
            State::Futex => "futex",
            State::Join => "join",
            State::Dying => "dying",
            State::Zombie => "zombie",
            State::Stopped => "stopped",
            State::Other(_) => "?",
        }
    }
}

/// A process (or thread) of the table, as `process` reports it
/// (SYS_PROC).
#[derive(Clone, Copy, Debug)]
pub struct ProcInfo {
    pub state: State,
    /// The process that started it; None for init.
    pub parent: Option<u32>,
    /// Pages it holds.
    pub pages: i32,
    /// Ticks it has run in user mode.
    pub cpu: i64,
    name: [u8; sys::PROC_NAME as usize],
}

impl ProcInfo {
    /// Its name, empty for none: a program of the kernel image names
    /// itself, a disk program is named after its argv[0].
    pub fn name(&self) -> &str {
        let n = self.name.iter().position(|&c| c == 0).unwrap_or(self.name.len());
        core::str::from_utf8(&self.name[..n]).unwrap_or("?")
    }
}

/// Process `pid` as it is now; None for a free slot or no such slot.
pub fn process(pid: u32) -> Option<ProcInfo> {
    let w: Words<{ sys::PROCINFO as usize + 4 }> = Words::new();
    if sys::call(sys::SYS_PROC, &[pid as i32, w.ptr() as i32]) < 0 {
        return None;
    }
    let mut name = [0u8; sys::PROC_NAME as usize];
    for (k, c) in name.iter_mut().enumerate() {
        *c = w.tryte(sys::PI_NAME + k as i32);
    }
    let parent = w.word(sys::PI_PARENT);
    Some(ProcInfo {
        state: State::from_raw(w.word(sys::PI_STATE)),
        parent: (parent >= 0).then_some(parent as u32),
        pages: w.word(sys::PI_PAGES),
        cpu: w.word_i64(sys::PI_CPU),
        name,
    })
}

/// Every slot in use, by number, from 0.
pub fn processes() -> impl Iterator<Item = (u32, ProcInfo)> {
    (0..sys::NPROC as u32).filter_map(|pid| process(pid).map(|p| (pid, p)))
}

/// What a hart has done with its time (SYS_HARTINFO).
#[derive(Clone, Copy, Debug)]
pub struct HartInfo {
    /// The time CSR as the kernel read the rest.
    pub time: i64,
    /// The time CSR when the kernel started it.
    pub started: i64,
    /// Ticks it has run processes in user mode.
    pub user: i64,
    /// Ticks it has waited for work; the rest since `started` it spent
    /// in the kernel.
    pub idle: i64,
}

/// Hart `hart`, -HART_MAX to HART_MAX; None if it is not present.
pub fn hart(hart: i32) -> Option<HartInfo> {
    let w: Words<{ sys::HARTINFO as usize + 4 }> = Words::new();
    if sys::call(sys::SYS_HARTINFO, &[hart, w.ptr() as i32]) < 0 {
        return None;
    }
    Some(HartInfo {
        time: w.word_i64(sys::HI_TIME),
        started: w.word_i64(sys::HI_STARTED),
        user: w.word_i64(sys::HI_USER),
        idle: w.word_i64(sys::HI_IDLE),
    })
}

/// Read the kernel's log (SYS_LOG) into `buf` from the `from`th code
/// point it ever printed (the oldest it keeps, if that one is gone):
/// how many it gave, 0 once it has given all, and where the next read
/// starts.
pub fn read_log(buf: &mut [u8], from: i32) -> io::Result<(usize, i32)> {
    let n = sys::check(sys::call(
        sys::SYS_LOG,
        &[buf.as_mut_ptr() as i32, buf.len() as i32, from],
    ))?;
    Ok((n as usize, sys::more(0)))
}

/// The whole log the kernel keeps: its last `sys::LOG_SIZE` code points.
pub fn log() -> io::Result<Vec<u8>> {
    let mut all = Vec::new();
    let mut buf = [0u8; 243];
    let mut from = 0;
    loop {
        let (n, next) = read_log(&mut buf, from)?;
        if n == 0 {
            return Ok(all);
        }
        all.extend_from_slice(&buf[..n]);
        from = next;
    }
}
