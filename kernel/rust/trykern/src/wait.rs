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
use crate::{desc, devices, ipc, names, thread};

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

/// kill(pid, for): end pid, a child of the caller, or with for not
/// FOR_SELF a child of process for. It goes the next time the kernel
/// would run it, which for one running on another hart is its next trap,
/// within a timer slice; its parent's wait then reports WAIT_KILLED. A
/// child that has ended already gives KILL_ENDED instead, so the console
/// server can tell that a Ctrl-C ended nothing. Only a driver may kill on
/// another's behalf: the console server, which ends the console's
/// foreground process at Ctrl-C with the authority of the process that
/// gave it the console. A driver is trusted with more than that already,
/// since its device can write any page. With KILL_ANY, any process but
/// init (bin/kill).
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_kill(p: *mut u8) {
    let p = Proc(p);
    let r = kill(p);
    p.set(PCB_A0, r);
}

fn kill(p: Proc) -> Word {
    let pid = p.get(PCB_A1);
    let on_behalf = p.get(PCB_A2);
    if on_behalf == KILL_ANY {
        let Some(q) = Proc::alive(pid) else {
            return E_NOPROC;
        };
        if q.space().pid() == 0 {
            return E_PERM; // init, which the rest needs, or a thread of it
        }
        kill_pid(pid);
        return 0;
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
        Ok(_) => {
            kill_pid(pid);
            0
        }
    }
}

/// Whether process `p` drives a device.
pub fn drives_any(p: Proc) -> bool {
    let me = p.addr_word();
    (0..NSRC).any(|k| load_at(kdata::drivers_base(), 3 * k) == me)
}

/// End process `pid`, every thread of it, if it has not ended; each
/// goes the next time the kernel would run it (ktrap, resume), and one
/// blocked in any system call (recv, wait, call, receive, lookup) is
/// made ready for that, since nothing else would wake it. A thread's
/// number ends its whole process.
fn kill_pid(pid: Word) {
    let q = Proc::of(pid);
    if q.is(ST_EXITED) || q.is(ST_ZOMBIE) {
        return; // already gone
    }
    thread::end(q.space(), WAIT_KILLED, 0);
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
}
