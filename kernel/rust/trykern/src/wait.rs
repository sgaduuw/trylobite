//! Processes ending and their parents waiting: wait, kill, and burying
//! a process once release has freed its pages. Exit codes outlive their
//! process in its record, which stays as ST_ZOMBIE until its parent
//! waits for it. How a process ended is kept in its saved a0
//! (WAIT_EXITED or WAIT_FAULTED) and a1 (the code or the cause): the
//! very registers its parent's wait returns.

use crate::kdata;
use crate::layout::*;
use crate::proc::Proc;
use crate::word::{Word, load_at};
use crate::{desc, devices, ipc, names, signal};

/// Process `pid` if it is a child of process `parent`, ended or not;
/// else E_NOCHILD.
fn child(pid: Word, parent: Word) -> Result<Proc, Word> {
    if !(0..NPROC).contains(&pid) {
        return Err(E_NOCHILD);
    }
    let c = Proc::of(pid);
    // A free slot is nobody's child.
    if !c.is(ST_EXITED) && c.get(PCB_PARENT) == parent {
        Ok(c)
    } else {
        Err(E_NOCHILD)
    }
}

/// wait(pid): how child pid ended, in a0 and a1; block until it has.
/// 1: it blocks, and the stub schedules; its bury hands over a0 and a1.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_wait(p: *mut u8) -> i32 {
    let p = Proc(p);
    match child(p.get(PCB_A1), p.space().pid()) {
        Err(e) => {
            p.set(PCB_A0, e);
            0
        }
        Ok(c) if c.is(ST_ZOMBIE) => {
            // It has ended: reap it.
            p.set(PCB_A1, c.get(PCB_A1));
            p.set(PCB_A0, c.get(PCB_A0));
            c.set(PCB_STATE, ST_EXITED);
            0
        }
        Ok(_) => {
            p.set(PCB_STATE, ST_WAIT);
            1
        }
    }
}

/// kill(pid, for, sig): send signal sig to pid, a child of the caller,
/// or with for not FOR_SELF a child of process for (signal.rs says what
/// it does there). One that ends goes the next time the kernel would run
/// it, which for one running on another hart is its next trap, within a
/// timer slice; its parent's wait then reports WAIT_KILLED and the
/// signal. A child that has ended already gives KILL_ENDED instead, and
/// one that goes on (it catches, ignores or blocks the signal)
/// KILL_CAUGHT, so the console server can tell what a Ctrl-C did. Only a
/// driver may signal on another's behalf: the console server, which
/// sends the console's foreground process SIGINT at Ctrl-C with the
/// authority of the process that gave it the console. A driver is
/// trusted with more than that already, since its device can write any
/// page. With KILL_ANY, any process but init (bin/kill). Signal 0 only
/// checks that the process is there.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_kill(p: *mut u8) {
    let p = Proc(p);
    let r = kill(p);
    p.set(PCB_A0, r);
}

fn kill(p: Proc) -> Word {
    let pid = p.get(PCB_A1);
    let on_behalf = p.get(PCB_A2);
    let sig = p.get(PCB_A3);
    if !(0..NSIG).contains(&sig) {
        return E_INVAL;
    }
    if on_behalf == KILL_ANY {
        let Some(q) = Proc::alive(pid) else {
            return E_NOPROC;
        };
        if q.space().pid() == 0 {
            return E_PERM; // init, which the rest needs, or a thread of it
        }
        return send(q, sig);
    }
    let parent = if on_behalf == FOR_SELF {
        p.space().pid() // a thread's children are its process's
    } else {
        if !drives_any(p) {
            return E_PERM;
        }
        on_behalf
    };
    match child(pid, parent) {
        Err(e) => e,
        Ok(c) if c.is(ST_ZOMBIE) => KILL_ENDED,
        Ok(c) => send(c, sig),
    }
}

/// Signal `sig` to the process of `q`, which has not ended; a thread's
/// number reaches its whole process.
fn send(q: Proc, sig: Word) -> Word {
    if sig == 0 { 0 } else { signal::post(q.space(), sig) }
}

/// Whether process `p` drives a device.
pub fn drives_any(p: Proc) -> bool {
    let me = p.addr_word();
    (0..NSRC).any(|k| load_at(kdata::drivers_base(), 3 * k) == me)
}

/// Process `p` has ended, after every thread of it, and its pages are
/// free (release, mm.rs).
/// Servers, devices, names and descriptors hear of it first. Then orphan
/// its children, freeing those already ended, since nobody can wait for
/// them now; hand how it ended to its parent if the parent waits for it,
/// else stay as a zombie until the parent does. A process with no
/// parent simply goes.
pub fn bury(p: Proc) {
    let pid = p.pid();
    // How it ended, as rk_release recorded it when it began to end.
    p.set(PCB_A0, p.get(PCB_HOW));
    p.set(PCB_A1, p.get(PCB_CODE));
    ipc::rk_ipc_ended(p.0, pid as i32); // servers learn of it
    devices::rk_drv_ended(p.0); // its devices go
    names::rk_srv_ended(pid as i32); // and its names
    desc::rk_desc_ended(p.0, pid as i32); // and its descriptors
    for q in Proc::table() {
        if q.get(PCB_PARENT) == pid {
            q.set(PCB_PARENT, NO_PARENT);
            if q.is(ST_ZOMBIE) {
                q.set(PCB_STATE, ST_EXITED);
            }
        } else if q.is(ST_ZOMBIE) && q != p && q.get(PCB_SPACE) == pid {
            q.set(PCB_STATE, ST_EXITED); // a thread nobody joined
        }
    }
    let parent = p.get(PCB_PARENT);
    if parent < 0 {
        p.set(PCB_STATE, ST_EXITED); // nobody to tell
        return;
    }
    let par = Proc::of(parent);
    if par.is(ST_WAIT) && par.get(PCB_A1) == pid {
        par.set(PCB_A0, p.get(PCB_A0));
        par.set(PCB_A1, p.get(PCB_A1));
        par.ready(); // a hart waiting for work can run it
        p.set(PCB_STATE, ST_EXITED);
    } else {
        p.set(PCB_STATE, ST_ZOMBIE); // it waits for another child, or none
    }
    signal::post(par, SIGCHLD); // which does nothing, unless it catches it
}
