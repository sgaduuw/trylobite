//! Threads (docs/kernel.md, Threads): more than one slot of the process
//! table running in one address space. A thread has a record of its own,
//! so its registers, state, coprocessor bank, messages, alarm and name
//! are its own, and every call that blocks blocks it alone; what it
//! shares with its process it reaches through PCB_SPACE (Proc::space):
//! memory (mem::user_at, window, brk), descriptors (desc.rs), children
//! (spawn, wait, kill) and the end.
//!
//! The process's first slot owns the pages and stays until the last of
//! its threads has gone. exit, a fault or a kill in any thread ends the
//! whole process (`end`): every thread is killed, and goes the next time
//! the kernel would run it, as a killed process does; the process waits
//! as ST_DYING until the last has, so no hart is still running in its
//! address space when its pages go back (mm::rk_release). A thread
//! that calls thread_exit goes alone, and stays as ST_ZOMBIE until
//! another thread of its process joins it (or the process ends).
//!
//! futex is the one way for threads to wait for each other besides
//! join: Rust's atomics make the lock (detrytus docs/rust.md, Atomics),
//! and a thread that finds it taken sleeps on its word until the holder
//! wakes it. The kernel lock makes the test and the sleep one step, so
//! a wake that comes after the holder's store cannot be missed.

use crate::console::{putn, puts};
use crate::layout::*;
use crate::mem::user_at;
use crate::mm;
use crate::proc::Proc;
use crate::syscall::{RELEASE, RESUME, SCHEDULE};
use crate::trytes;
use crate::word::Word;
use crate::{devices, ipc, names};

unsafe extern "C" {
    static msg_proc: u8;
    static msg_killed: u8;
}

/// The caller's result is `r`, and it goes on.
fn done(p: Proc, r: Word) -> i32 {
    p.set(PCB_A0, r);
    RESUME
}

/// thread(entry, stack, arg, tp): start a thread of the caller's
/// process. It runs from entry with sp = stack, a0 = arg and tp = tp
/// (the thread's own data, say), and the caller's gp, in a slot of its
/// own; its number, or E_NOSLOT.
pub fn sys_thread(p: Proc) -> i32 {
    let sp = p.space();
    let Some(t) = mm::free_slot() else {
        return done(p, E_NOSLOT);
    };
    mm::claim(t, sp);
    t.set(PCB_PARENT, NO_PARENT); // the process's children are its own
    t.set(PCB_FILE, sp.get(PCB_FILE)); // what it may drive
    trytes::copy(sp.at(PCB_NAME), t.at(PCB_NAME), PROC_NAME as usize);
    t.set(PCB_PTBR, mm::ptbr(sp.get(PCB_ROOTPG), t));
    t.set(PCB_PC, p.get(PCB_A1));
    t.set(PCB_SP, p.get(PCB_A2));
    t.set(PCB_A0, p.get(PCB_A3));
    t.set(PCB_TP, p.get(PCB_A4));
    t.set(PCB_GP, p.get(PCB_GP));
    sp.set(PCB_THREADS, sp.get(PCB_THREADS) + 1);
    t.ready(); // a hart waiting for work can run it
    done(p, t.pid())
}

/// thread_exit(code): end the calling thread alone; its code waits in
/// its saved a1 for join. A process's first thread cannot: it owns the
/// pages, and ends with exit.
pub fn sys_texit(p: Proc) -> i32 {
    if !p.is_thread() {
        return done(p, E_PERM);
    }
    p.set(PCB_TEXIT, 1);
    RELEASE
}

/// join(tid, how): the code thread tid ended with, in a1, once it has;
/// with JOIN_WAIT the caller sleeps until then (bury hands it over),
/// with JOIN_POLL it gets E_BUSY. Only another thread of the caller's
/// process can be joined, and only once.
pub fn sys_join(p: Proc) -> i32 {
    let (tid, how) = (p.get(PCB_A1), p.get(PCB_A2));
    if (how != JOIN_WAIT && how != JOIN_POLL) || tid == p.pid() {
        return done(p, E_INVAL);
    }
    let Some(t) = thread_of(p.space(), tid) else {
        return done(p, E_NOCHILD);
    };
    if t.is(ST_ZOMBIE) {
        p.set(PCB_A1, t.get(PCB_A1));
        t.set(PCB_STATE, ST_EXITED); // the slot is free
        return done(p, 0);
    }
    if how == JOIN_POLL {
        return done(p, E_BUSY);
    }
    p.set(PCB_STATE, ST_JOIN);
    SCHEDULE
}

/// Thread `tid` of process `sp`, ended or not: a slot in its space that
/// is not the process's own.
fn thread_of(sp: Proc, tid: Word) -> Option<Proc> {
    if !(0..NPROC).contains(&tid) {
        return None;
    }
    let t = Proc::of(tid);
    (!t.is(ST_EXITED) && t != sp && t.get(PCB_SPACE) == sp.pid()).then_some(t)
}

/// futex(address, op, value): FUTEX_WAIT sleeps while the u32 at
/// address is value; FUTEX_WAKE wakes at most value of the threads of
/// the caller's process sleeping at address, and gives how many.
pub fn sys_futex(p: Proc) -> i32 {
    let (at, op, value) = (p.get(PCB_A1), p.get(PCB_A2), p.get(PCB_A3));
    if op == FUTEX_WAIT {
        let Some(now) = load_u32(p, at) else {
            return done(p, E_FAULT);
        };
        if now != value as u32 {
            return done(p, E_AGAIN);
        }
        p.set(PCB_STATE, ST_FUTEX); // FUTEX_WAKE makes it ready, with 0
        return SCHEDULE;
    }
    if op != FUTEX_WAKE || value < 0 {
        return done(p, E_INVAL);
    }
    let sp = p.space().pid();
    let mut woken = 0;
    for q in Proc::table() {
        if woken >= value {
            break;
        }
        if q.is(ST_FUTEX) && q.get(PCB_A1) == at && q.get(PCB_SPACE) == sp {
            q.set(PCB_A0, 0);
            q.ready();
            woken += 1;
        }
    }
    done(p, woken)
}

/// The u32 at user address `at` of `p`, as Rust keeps one: four trytes,
/// low byte first, each 0 to 255. Each tryte is looked up alone, as a
/// u32 may straddle two pages. None if any is not there.
fn load_u32(p: Proc, at: Word) -> Option<u32> {
    let mut v = 0u32;
    for k in 0..4 {
        let t = user_at(p, at + k);
        if t.is_null() {
            return None;
        }
        v |= (trytes::get(t) as u32 & 255) << (8 * k as u32);
    }
    Some(v)
}

/// gettid(): the caller's own slot; for a process's first thread, the
/// process number getpid gives.
pub fn sys_gettid(p: Proc) -> i32 {
    done(p, p.pid())
}

/// End process `sp`, as `how` and `code` say (its saved a0 and a1 once
/// it is buried, for its parent's wait), unless it is ending already:
/// mark it and each of its threads killed, so each goes the next time
/// the kernel would run it (rk_on_kill), and make those that wait
/// ready for that.
pub fn end(sp: Proc, how: Word, code: Word) {
    if sp.get(PCB_ENDING) != 0 {
        return;
    }
    sp.set(PCB_ENDING, 1);
    sp.set(PCB_HOW, how);
    sp.set(PCB_CODE, code);
    kill_one(sp);
    if sp.get(PCB_THREADS) == 0 {
        return; // most processes have none: no walk
    }
    let me = sp.pid();
    for q in Proc::table() {
        if q != sp && q.get(PCB_SPACE) == me {
            kill_one(q);
        }
    }
}

/// Mark `q` killed, if it has not ended; one blocked in a system call is
/// made ready, since nothing else would wake it.
fn kill_one(q: Proc) {
    if q.is(ST_EXITED) || q.is(ST_ZOMBIE) || q.is(ST_DYING) {
        return; // already gone
    }
    q.set(PCB_KILLED, 1);
    if q.state() < 0 {
        q.ready();
    }
}

/// The process or thread in `p` was found killed (on_kill in
/// kernel/trap.s): it ends as WAIT_KILLED. Its process says so once,
/// when a kill ended it rather than an exit or a fault in a thread.
#[unsafe(no_mangle)]
pub extern "C" fn rk_on_kill(p: *mut u8) {
    let p = Proc(p);
    p.set(PCB_KILLED, 0);
    let sp = p.space();
    end(sp, WAIT_KILLED, 0); // ending already, as kill marks it
    if p == sp && sp.get(PCB_HOW) == WAIT_KILLED {
        puts(unsafe { &raw const msg_proc });
        putn(sp.pid() as i32);
        puts(unsafe { &raw const msg_killed });
    }
    p.set(PCB_A0, WAIT_KILLED);
    p.set(PCB_A1, 0);
}

/// Thread `t` of process `sp` has ended (rk_release). Servers, devices
/// and names hear of it, as of a process; its descriptors are the
/// process's, and stay. Its code goes to a thread waiting in join for
/// it, else it stays as ST_ZOMBIE for one; when the process is ending,
/// nobody will join, and the slot is free at once.
pub fn bury(t: Proc, sp: Proc) {
    let tid = t.pid();
    ipc::rk_ipc_ended(t.0, tid as i32);
    devices::rk_drv_ended(t.0);
    names::rk_srv_ended(tid as i32);
    sp.set(PCB_THREADS, sp.get(PCB_THREADS) - 1);
    if sp.get(PCB_ENDING) != 0 {
        t.set(PCB_STATE, ST_EXITED);
        return;
    }
    let mut taken = false;
    let me = sp.pid();
    for q in Proc::table() {
        if q.is(ST_JOIN) && q.get(PCB_A1) == tid && q.get(PCB_SPACE) == me {
            if taken {
                q.set(PCB_A0, E_NOCHILD); // another join had it
            } else {
                q.set(PCB_A0, 0);
                q.set(PCB_A1, t.get(PCB_A1));
                taken = true;
            }
            q.ready();
        }
    }
    t.set(PCB_STATE, if taken { ST_EXITED } else { ST_ZOMBIE });
}
