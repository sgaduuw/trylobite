//! Signals (docs/kernel.md, Signals): POSIX's, kept small. The kernel
//! keeps, for each process, the signals sent and not yet taken
//! (PCB_SIGPEND), which it catches and which it ignores, and one entry
//! point for every caught signal (PCB_SIGENTRY); which handler runs for
//! which signal is the program's business (trystd's signal table). Each
//! thread has its own mask of blocked signals (PCB_SIGMASK).
//!
//! Sending (`post`) marks the signal pending and sets PCB_SIGNOTE in
//! every thread that does not block it; resume looks at that one word on
//! its way back to user mode, and calls `rk_signal`, which takes one
//! signal and acts on it: ends the process, or pushes a frame of the
//! thread's registers onto its stack and runs the entry, which returns
//! through sigreturn. A signal whose action is to end the process ends
//! it at once if any thread lets it in, as kill always has.
//!
//! Stop signals (SIGSTOP, and by default SIGTSTP, SIGTTIN and SIGTTOU)
//! stop the process rather than end it (docs/kernel.md, Job control):
//! PCB_STOP says so, its parent hears (waitpid with WAIT_UNTRACED, and
//! SIGCHLD), and each of its threads parks as ST_STOPPED the next time
//! it would go back to user mode, which rk_signal sees to, as the note
//! is set for each. A thread blocked in a call stays blocked, and parks
//! when the call ends. SIGCONT, whatever its action, sets the process
//! going again: its parked threads are ready once more.
//!
//! A thread blocked in a system call when a caught signal comes is woken
//! with E_INTR, so its handler runs now rather than whenever the call
//! would have ended: any blocking state but ST_REPLY, where a server
//! holds its call and the reply is still to come (the console server
//! answers its own held reads with E_INTR at Ctrl-C). Such a call had
//! not happened yet, so calling again is always right, and trystd does.

use crate::layout::*;
use crate::mem::user_at;
use crate::proc::Proc;
use crate::syscall::{RESUME, SCHEDULE};
use crate::{jobs, thread};
use crate::kdata;
use crate::word::{Word, load, load_small_at, store};

/// The bit for signal `sig` in a set.
fn bit(sig: Word) -> i32 {
    1 << sig as i32
}

/// Every signal there is, SIGKILL and SIGSTOP excepted: what a mask
/// may hold.
const MASKABLE: i32 =
    ((1i64 << NSIG) - 2) as i32 & !(1 << SIGKILL as i32) & !(1 << SIGSTOP as i32);

/// The signals that stop a process by default.
const STOPS: i32 = (1 << SIGSTOP as i32)
    | (1 << SIGTSTP as i32)
    | (1 << SIGTTIN as i32)
    | (1 << SIGTTOU as i32);

/// Whether nothing can change what signal `sig` does: SIGKILL and SIGSTOP.
fn fixed(sig: Word) -> bool {
    sig == SIGKILL || sig == SIGSTOP
}

/// What a signal does to a process.
#[derive(PartialEq, Eq, Clone, Copy)]
enum Action {
    End,
    Ignore,
    Catch,
    Stop,
}

/// What signal `sig` does to process `sp` now.
fn action(sp: Proc, sig: Word) -> Action {
    let b = bit(sig);
    if sig == SIGKILL {
        Action::End
    } else if sig == SIGSTOP {
        Action::Stop
    } else if load_small_at(sp.0, PCB_SIGCATCH) & b != 0 {
        Action::Catch
    } else if load_small_at(sp.0, PCB_SIGIGN) & b != 0 || sig == SIGCHLD || sig == SIGCONT {
        Action::Ignore
    } else if STOPS & b != 0 {
        Action::Stop
    } else {
        Action::End
    }
}

fn set_of(p: Proc, field: Word) -> i32 {
    load_small_at(p.0, field)
}

/// Each thread of process `sp`, the process first; most have none, and
/// then there is no walk.
fn each_thread(sp: Proc, mut f: impl FnMut(Proc)) {
    f(sp);
    if sp.get(PCB_THREADS) == 0 {
        return;
    }
    let me = sp.pid();
    for q in Proc::table() {
        if q != sp && !q.is(ST_EXITED) && !q.is(ST_ZOMBIE) && q.get(PCB_SPACE) == me {
            f(q);
        }
    }
}

/// Send signal `sig` (1 to NSIG - 1) to process `sp`: 0 if it ends,
/// KILL_STOPPED if it stops, KILL_CAUGHT if it goes on (caught,
/// ignored, or blocked by every thread for now).
pub fn post(sp: Proc, sig: Word) -> Word {
    if sp.get(PCB_ENDING) != 0 {
        return 0; // ending already
    }
    let b = bit(sig);
    // A stop and a continue each undo the other, waiting or done.
    if sig == SIGCONT {
        sp.set(PCB_SIGPEND, (set_of(sp, PCB_SIGPEND) & !STOPS) as Word);
        cont(sp);
    } else if STOPS & b != 0 {
        sp.set(PCB_SIGPEND, (set_of(sp, PCB_SIGPEND) & !bit(SIGCONT)) as Word);
    }
    let act = action(sp, sig);
    if act == Action::Ignore {
        return KILL_CAUGHT;
    }
    let mut open = false; // whether any thread lets it in
    each_thread(sp, |t| open |= fixed(sig) || set_of(t, PCB_SIGMASK) & b == 0);
    if act == Action::End && open {
        thread::end(sp, WAIT_KILLED, sig);
        return 0;
    }
    if act == Action::Stop && open {
        stop(sp, sig);
        return KILL_STOPPED;
    }
    sp.set(PCB_SIGPEND, (set_of(sp, PCB_SIGPEND) | b) as Word);
    if !open {
        return KILL_CAUGHT; // it waits for a thread to unblock it
    }
    // Every thread that lets it in looks at resume; if none of them is
    // running or ready, wake one that waits.
    let mut busy = false;
    each_thread(sp, |t| {
        if set_of(t, PCB_SIGMASK) & b == 0 {
            t.set(PCB_SIGNOTE, 1);
            busy |= t.is(ST_READY) || t.is(ST_RUNNING);
        }
    });
    if !busy {
        let mut woken = false;
        each_thread(sp, |t| {
            if !woken && set_of(t, PCB_SIGMASK) & b == 0 && interruptible(t) {
                t.set(PCB_A0, E_INTR);
                t.set(PCB_RETRY, 0);
                t.ready();
                woken = true;
            }
        });
    }
    KILL_CAUGHT
}

/// Whether thread `t` waits in a system call a signal may cut short:
/// any but a call a server holds (ST_REPLY), and not an ending, nor a
/// stopped thread, which takes its signals once it goes on.
fn interruptible(t: Proc) -> bool {
    let s = t.state();
    s < 0 && ![ST_REPLY, ST_ZOMBIE, ST_DYING, ST_STOPPED].iter().any(|&x| s == x as i32)
}

/// Stop process `sp` by signal `sig`: each thread parks on its way to
/// user mode (rk_signal), and its parent hears of it.
fn stop(sp: Proc, sig: Word) {
    if sp.get(PCB_STOP) != 0 {
        return; // stopped already
    }
    sp.set(PCB_STOP, sig);
    sp.set(PCB_STOPWAIT, 1);
    each_thread(sp, |t| t.set(PCB_SIGNOTE, 1));
    jobs::stopped(sp, sig);
}

/// Set stopped process `sp` going again: each thread parked is ready,
/// and each takes the signals waiting for it as it goes.
fn cont(sp: Proc) {
    if sp.get(PCB_STOP) == 0 && sp.get(PCB_HELD) == 0 {
        return;
    }
    sp.set(PCB_STOP, 0);
    sp.set(PCB_HELD, 0);
    sp.set(PCB_STOPWAIT, 0); // a stop gone before anyone heard of it
    unpark(sp);
}

/// Process `sp` may go on (no longer stopped or held): each thread
/// parked is ready, and each takes the signals waiting for it as it
/// goes. One still stopped stays parked.
pub fn unpark(sp: Proc) {
    if sp.get(PCB_STOP) != 0 || sp.get(PCB_HELD) != 0 {
        return;
    }
    each_thread(sp, |t| {
        if t.is(ST_STOPPED) {
            t.ready();
        }
        renote(t);
    });
}

/// Thread `t` has just gone to sleep in a system call with PCB_SIGNOTE
/// set (rk_syscall): if a signal it lets in waits, and the sleep is one
/// a signal may cut short, wake it with E_INTR, so it takes the signal
/// rather than sleeping on with it. What its call does next: SCHEDULE
/// still, as it is no longer running either way.
pub fn interrupt_sleeper(t: Proc) -> i32 {
    let open = set_of(t.space(), PCB_SIGPEND) & !set_of(t, PCB_SIGMASK);
    if open != 0 && interruptible(t) {
        t.set(PCB_A0, E_INTR);
        t.set(PCB_RETRY, 0);
        t.ready();
    }
    SCHEDULE
}

/// Recompute whether thread `t` may have a signal to take.
fn renote(t: Proc) {
    let open = set_of(t.space(), PCB_SIGPEND) & !set_of(t, PCB_SIGMASK);
    t.set(PCB_SIGNOTE, (open != 0) as Word);
}

/// Thread `p` is about to run and its PCB_SIGNOTE is set (resume in
/// kernel/trap.s): take one signal it does not block and act on it, or
/// clear the note if there is none. resume then looks again, so each
/// signal waiting gets its turn, a frame on the one before. 1 when the
/// thread parks instead, its process stopped: another runs (pick), and
/// the note stays, so that it looks again when it goes on.
#[unsafe(no_mangle)]
pub extern "C" fn rk_signal(p: *mut u8) -> i32 {
    let t = Proc(p);
    let sp = t.space();
    if sp.get(PCB_ENDING) != 0 {
        t.set(PCB_SIGNOTE, 0);
        return 0;
    }
    if sp.get(PCB_STOP) != 0 || sp.get(PCB_HELD) != 0 {
        t.set(PCB_STATE, ST_STOPPED);
        return 1;
    }
    let open = set_of(sp, PCB_SIGPEND) & !set_of(t, PCB_SIGMASK);
    if open == 0 {
        t.set(PCB_SIGNOTE, 0);
        return 0;
    }
    let mut sig = 1;
    while open & bit(sig) == 0 {
        sig += 1;
    }
    sp.set(PCB_SIGPEND, (set_of(sp, PCB_SIGPEND) & !bit(sig)) as Word);
    match action(sp, sig) {
        Action::Ignore => {}
        Action::End => thread::end(sp, WAIT_KILLED, sig),
        Action::Stop => {
            // One blocked until now: it stops the process here.
            stop(sp, sig);
            t.set(PCB_STATE, ST_STOPPED);
            return 1;
        }
        Action::Catch => {
            if !deliver(t, sp, sig) {
                // Nowhere to put the frame: as a fault would, it ends.
                thread::end(sp, WAIT_KILLED, sig);
            }
        }
    }
    0
}

/// Push thread `t`'s registers, pc, coprocessor bank and mask onto its
/// stack as a SIGFRAME, block `sig` while its handler runs, and start
/// the process's entry with a0 = sig, a1 = the frame and sp just below
/// it. A server woken to run receive again (PCB_RETRY) gets E_INTR from
/// it instead. false if the stack is not the process's memory.
fn deliver(t: Proc, sp: Proc, sig: Word) -> bool {
    if t.get(PCB_RETRY) != 0 {
        t.set(PCB_RETRY, 0);
        t.set(PCB_A0, E_INTR);
    }
    let top = t.get(PCB_SP);
    let frame = top - top.rem_euclid(3) - SIGFRAME;
    let mask = t.get(PCB_SIGMASK);
    for k in 0..SIGFRAME / 3 {
        let off = 3 * k;
        let w = if off < SF_PC {
            t.get(off)
        } else if off == SF_PC {
            t.get(PCB_PC)
        } else if off < SF_MASK {
            t.get(PCB_FPU + off - SF_FPU)
        } else if off == SF_MASK {
            mask
        } else {
            sig
        };
        let at = user_at(t, frame + off);
        if at.is_null() {
            return false;
        }
        store(at, w);
    }
    t.set(PCB_SIGMASK, (mask as i32 | (bit(sig) & MASKABLE)) as Word);
    t.set(PCB_PC, sp.get(PCB_SIGENTRY));
    t.set(PCB_SP, frame);
    t.set(PCB_A0, sig);
    t.set(PCB_A1, frame);
    t.set(3, 0); // ra: the entry never returns, it calls sigreturn
    renote(t);
    true
}

/// sigreturn(frame): the thread goes back to where the frame says,
/// with its registers, coprocessor bank and mask; the thread's own tp
/// and gp come back too, as everything else does. Its call returns
/// nothing of its own: a0 is the frame's.
pub fn sys_sigreturn(t: Proc) -> i32 {
    let frame = t.get(PCB_A1);
    for k in 0..SIGFRAME / 3 {
        if user_at(t, frame + 3 * k).is_null() {
            t.set(PCB_A0, E_FAULT);
            return RESUME;
        }
    }
    let w = |off: Word| load(user_at(t, frame + off));
    for k in 0..SF_PC / 3 {
        if k != 13 {
            t.set(3 * k, w(3 * k)); // every register (word 13 is no register)
        }
    }
    t.set(PCB_PC, w(SF_PC));
    for k in 0..FPU_REGS {
        t.set(PCB_FPU + 3 * k, w(SF_FPU + 3 * k));
    }
    // The bank changed under the hart that last ran it: no hart holds it
    // now, so resume loads it from the record.
    let mut owner = kdata::fpu_owner_base();
    for _ in 0..NHART as i32 {
        if load(owner) == t.addr_word() {
            store(owner, 0);
        }
        owner = owner.wrapping_offset(3);
    }
    let mask = w(SF_MASK);
    let mask = if (0..1 << NSIG).contains(&mask) { mask as i32 & MASKABLE } else { 0 };
    t.set(PCB_SIGMASK, mask as Word);
    renote(t);
    RESUME
}

/// sigaction(sig, action, entry).
pub fn sys_sigaction(p: Proc) -> i32 {
    let (sig, how, entry) = (p.get(PCB_A1), p.get(PCB_A2), p.get(PCB_A3));
    if sig <= 0 || sig >= NSIG || !(SIG_DFL..=SIG_CATCH).contains(&how) {
        return done(p, E_INVAL);
    }
    if fixed(sig) && how != SIG_DFL {
        return done(p, E_INVAL);
    }
    let sp = p.space();
    let b = bit(sig);
    let (catch, ign) = (set_of(sp, PCB_SIGCATCH), set_of(sp, PCB_SIGIGN));
    let was = if catch & b != 0 {
        SIG_CATCH
    } else if ign & b != 0 {
        SIG_IGN
    } else {
        SIG_DFL
    };
    let (mut catch, mut ign) = (catch & !b, ign & !b);
    if how == SIG_CATCH {
        catch |= b;
        sp.set(PCB_SIGENTRY, entry);
    } else if how == SIG_IGN {
        ign |= b;
    }
    sp.set(PCB_SIGCATCH, catch as Word);
    sp.set(PCB_SIGIGN, ign as Word);
    if action(sp, sig) == Action::Ignore {
        // One waiting goes: it would only be thrown away.
        sp.set(PCB_SIGPEND, (set_of(sp, PCB_SIGPEND) & !b) as Word);
    }
    done(p, was)
}

/// sigmask(how, set): the calling thread's blocked set.
pub fn sys_sigmask(p: Proc) -> i32 {
    let (how, set) = (p.get(PCB_A1), p.get(PCB_A2));
    if !(0..1 << NSIG).contains(&set) {
        return done(p, E_INVAL);
    }
    let set = set as i32 & MASKABLE;
    let old = set_of(p, PCB_SIGMASK);
    let new = match how {
        SIG_BLOCK => old | set,
        SIG_UNBLOCK => old & !set,
        SIG_SETMASK => set,
        _ => return done(p, E_INVAL),
    };
    p.set(PCB_SIGMASK, new as Word);
    renote(p); // one it now lets in is taken before it runs on
    done(p, old as Word)
}

/// A new process `c` of parent `parent` (spawn): as across fork and
/// exec, it keeps what its parent ignores and blocks; what the parent
/// caught is its default again, since the handlers are not there. It
/// joins the group the parent chose for its children (jobs.rs).
pub fn inherit(c: Proc, parent: Word) {
    if !(0..NPROC).contains(&parent) {
        c.set(PCB_PGRP, c.pid()); // init, or an orphan: a group of its own
        return;
    }
    let par = Proc::of(parent);
    jobs::join(c, par.space());
    c.set(PCB_SIGIGN, par.space().get(PCB_SIGIGN));
    c.set(PCB_SIGMASK, par.get(PCB_SIGMASK));
}

/// A new thread `t`, started by thread `p`: it starts with p's mask.
pub fn inherit_thread(t: Proc, p: Proc) {
    t.set(PCB_SIGMASK, p.get(PCB_SIGMASK));
    renote(t);
}

/// The caller's result is `r`, and it goes on.
fn done(p: Proc, r: Word) -> i32 {
    p.set(PCB_A0, r);
    RESUME
}
