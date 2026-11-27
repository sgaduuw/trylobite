//! Processes as system tools see them: what each is (proc, name), and
//! waiting for the clock (sleep, alarm). The kernel keeps a name and a
//! count of user-mode ticks in each record for this; the tools format.
//! kernel/proc.s keeps the stubs.

use crate::layout::*;
use crate::mem::uva;
use crate::proc::Proc;
use crate::trytes;
use crate::word::{Word, store_at, time};

/// proc(pid, buffer): the PI_ words of process pid at buffer.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_proc(p: *mut u8) {
    let p = Proc(p);
    let r = proc_info(p);
    p.set(PCB_A0, r);
}

fn proc_info(p: Proc) -> Word {
    let pid = p.get(PCB_A1);
    if !(0..NPROC).contains(&pid) || Proc::of(pid).is(ST_EXITED) {
        return E_NOPROC; // out of range, or a free slot
    }
    let q = Proc::of(pid);
    let at = p.get(PCB_A2);
    if at % 3 != 0 {
        return E_FAULT; // words must be aligned
    }
    let Some((first, left)) = uva(p, at + PI_STATE - 1) else {
        return E_FAULT;
    };
    if left < PROCINFO {
        return E_FAULT; // not all in one page
    }
    // The buffer, as its words see it.
    let b = first.wrapping_offset((1 - PI_STATE) as isize);
    let state = q.get(PCB_STATE);
    store_at(b, PI_STATE, state);
    store_at(b, PI_PARENT, q.get(PCB_PARENT));
    let pages = if state == ST_ZOMBIE {
        0 // none once it has ended
    } else {
        // Its own, each image page above it and window it has, its heap.
        let mut pages = PAGES_PER_PROCESS + q.get(PCB_HEAP);
        for k in 0..NXPAGE + NWIN {
            if q.get(PCB_XPAGES + 3 * k) != 0 {
                pages += 1;
            }
        }
        pages
    };
    store_at(b, PI_PAGES, pages);
    store_at(b, PI_CPU, q.get(PCB_CPU));
    trytes::copy(
        q.at(PCB_NAME),
        b.wrapping_offset(PI_NAME as isize),
        PROC_NAME as usize,
    );
    0
}

/// name(string): name the caller after the string at a1.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_name(p: *mut u8) {
    let p = Proc(p);
    let r = match uva(p, p.get(PCB_A1)) {
        Some((at, left)) => {
            name(p, at, left);
            0
        }
        None => E_FAULT,
    };
    p.set(PCB_A0, r);
}

/// Name process `p` after the string at kernel address `at`, `left`
/// trytes of it mapped (spawnw, through proc_name in kernel/proc.s).
#[unsafe(no_mangle)]
pub extern "C" fn rk_proc_name(p: *mut u8, at: *mut u8, left: i32) {
    name(Proc(p), at, left as Word);
}

/// The string's part after its last /, PROC_NAME_MAX code points of it
/// at most, 0-padded.
fn name(p: Proc, at: *mut u8, left: Word) {
    let mut start = 0; // where the name starts so far
    let mut end = 0;
    while end < left {
        let t = trytes::get(at.wrapping_offset(end as isize));
        if t == 0 {
            break;
        }
        end += 1;
        if t == b'/' {
            start = end; // it starts after the /
        }
    }
    let n = (end - start).min(PROC_NAME_MAX);
    let to = p.at(PCB_NAME);
    for k in 0..PROC_NAME {
        let t = if k < n {
            trytes::get(at.wrapping_offset((start + k) as isize))
        } else {
            0
        };
        trytes::put(to.wrapping_offset(k as isize), t);
    }
}

/// sleep(until): wait until the clock reaches until. wake_sleepers
/// (sched.rs), which pick runs while anyone sleeps, makes it ready
/// again; a hart with nothing to run sets its timer for the earliest
/// (idle, kernel/sched.s). 1: it sleeps, and the stub schedules.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_sleep(p: *mut u8) -> i32 {
    let p = Proc(p);
    p.set(PCB_A0, 0); // what it returns, now or once woken
    if time() >= p.get(PCB_A1) {
        return 0; // that time has come
    }
    p.set(PCB_STATE, ST_SLEEP); // its saved a1 keeps the time
    crate::sched::sleeps_until(p.get(PCB_A1));
    1
}

/// alarm(until): set the caller's alarm, or cancel it with NO_ALARM. It
/// waits with the sleepers: wake_sleepers rings it.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_alarm(p: *mut u8) {
    let p = Proc(p);
    p.set(PCB_ALARM, 0);
    let until = p.get(PCB_A1);
    if until >= 0 {
        // 0 means none: time 1 has come as surely.
        p.set(PCB_ALARM, until.max(1));
        crate::sched::sleeps_until(until.max(1));
    }
    p.set(PCB_A0, 0);
}
