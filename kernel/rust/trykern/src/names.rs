//! Server names: a server registers a name, with the version of the
//! protocol it speaks, once it is ready for calls; a client looks the
//! name up to find the server's process number, and can sleep until it
//! is there. So no server needs a fixed process number, and a client
//! that starts before its server waits instead of failing.
//!
//! The kernel keeps the names, not a server: a naming server would need
//! a fixed number itself, take one of the NPROC slots, and cost every
//! lookup a call and a reply. The kernel also sees every process end
//! (bury), so a name goes the moment its server does, with no notice to
//! pass on: a name that is there belongs to a live process.
//!
//! The records are `names` in kernel/data.s, NSRV of SRV trytes. One is
//! free while its SRV_VERSION is 0. Names are compared whole,
//! zero-padded to SRV_NAME_MAX + 1 trytes.

use crate::kdata;
use crate::layout::*;
use crate::mem::uva;
use crate::proc::Proc;
use crate::trytes;
use crate::word::{Word, load_at, store_at};

const KEY: usize = (SRV_NAME_MAX + 1) as usize;

/// A name as a call gave it, zero-padded.
type Key = [u8; KEY];

/// Record `i`.
fn record(i: Word) -> *mut u8 {
    kdata::names_base().wrapping_offset((i as i32 * SRV as i32) as isize) // 32-bit: no helper call
}

fn records() -> impl Iterator<Item = *mut u8> {
    (0..NSRV).map(record)
}

/// register(name, version)
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_register(p: *mut u8) {
    let p = Proc(p);
    let r = register(p);
    p.set(PCB_A0, r);
}

fn register(p: Proc) -> Word {
    let version = p.get(PCB_A2);
    if version <= 0 {
        return E_INVAL;
    }
    let key = match key_in(p, p.get(PCB_A1)) {
        Ok(key) => key,
        Err(e) => return e,
    };
    let pid = p.pid();
    let r = match find(&key) {
        Some(r) if load_at(r, SRV_PID) != pid => return E_EXIST,
        Some(r) => r, // its own name: a new version
        None => {
            let Some(r) = records().find(|&r| load_at(r, SRV_VERSION) == 0) else {
                return E_NOSPC;
            };
            trytes::copy(key.as_ptr(), r.wrapping_offset(SRV_NAME as isize), KEY);
            store_at(r, SRV_PID, pid);
            r
        }
    };
    store_at(r, SRV_VERSION, version);
    wake_lookups();
    0
}

/// lookup(name, how, pid): sleeping in it, a process is woken by every
/// register and every process that ends, and runs it again (PCB_RETRY),
/// so it changes nothing before it finds the name. With LOOKUP_WHILE it
/// stops waiting once process pid has ended, or if it never was: init
/// waits so for a server it has just started, which may end before it
/// registers. 1: it sleeps, and kernel/names.s schedules.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_lookup(p: *mut u8) -> i32 {
    let p = Proc(p);
    match lookup(p) {
        Some(r) => {
            p.set(PCB_A0, r);
            0
        }
        None => {
            p.set(PCB_STATE, ST_LOOKUP);
            1
        }
    }
}

/// The result, or None to sleep.
fn lookup(p: Proc) -> Option<Word> {
    let how = p.get(PCB_A2);
    let key = match key_in(p, p.get(PCB_A1)) {
        Ok(key) => key,
        Err(e) => return Some(e),
    };
    if let Some(r) = find(&key) {
        p.set(PCB_A1, load_at(r, SRV_VERSION));
        return Some(load_at(r, SRV_PID));
    }
    match how {
        LOOKUP_WAIT => None,
        LOOKUP_WHILE => {
            // Is pid still there? Gone, a free slot or ended: no.
            let pid = p.get(PCB_A3);
            Proc::alive(pid).map_or(Some(E_NOPROC), |_| None)
        }
        _ => Some(E_NOENT),
    }
}

/// The name at `at` in the caller's memory (its page, a block window or
/// heap it has, on across pages), zero-padded: E_FAULT if it leaves the
/// caller's memory before its 0, E_NAMETOOLONG, or E_INVAL (empty).
fn key_in(p: Proc, mut at: Word) -> Result<Key, Word> {
    let mut key: Key = [0; KEY];
    let mut n = 0; // trytes copied before the 0
    loop {
        let Some((mut from, mut left)) = uva(p, at) else {
            return Err(E_FAULT);
        };
        while left > 0 {
            let t = trytes::get(from);
            if t == 0 {
                return if n == 0 { Err(E_INVAL) } else { Ok(key) };
            }
            trytes::put(&raw mut key[n], t);
            n += 1;
            if n == KEY {
                return Err(E_NAMETOOLONG);
            }
            from = from.wrapping_add(1);
            at += 1;
            left -= 1;
        }
    }
}

/// The record named `key`.
fn find(key: &Key) -> Option<*mut u8> {
    records().find(|&r| {
        load_at(r, SRV_VERSION) != 0
            && trytes::same(key.as_ptr(), r.wrapping_offset(SRV_NAME as isize), KEY)
    })
}

/// A name came or changed, or a process ended: every process asleep in
/// lookup looks again.
fn wake_lookups() {
    for q in Proc::table() {
        q.retry_if(ST_LOOKUP);
    }
}

/// Process `pid` has ended (bury, through srv_ended): its names go, and
/// whoever waits in lookup looks again, as one may wait only while it
/// lives.
#[unsafe(no_mangle)]
pub extern "C" fn rk_srv_ended(pid: i32) {
    let pid = pid as Word;
    for r in records() {
        if load_at(r, SRV_PID) == pid {
            store_at(r, SRV_VERSION, 0);
        }
    }
    wake_lookups();
}
