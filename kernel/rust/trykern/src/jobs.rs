//! Job control (docs/kernel.md, Job control): process groups, signals
//! to a whole group, and a parent hearing that a child stopped. Stopping
//! and continuing themselves are signals' (signal.rs).
//!
//! A group is named by its leader's process number and lives in each
//! member's record (PCB_PGRP). A new process joins the group its parent
//! chose for its children (PCB_CPGRP): the parent's own, at first. The
//! shell chooses a new group for a job's first program and that group
//! for the rest before it starts them, so that no program of a job ever
//! runs outside it: setpgrp on a child already running would leave a
//! moment in which the console's foreground is not its group. A
//! foreground job's programs also start held (PCB_CHELD, PCB_HELD),
//! and the shell lets them go once their group has the console: else
//! one could read the console before then, and be stopped for it
//! (SIGTTIN). Held is not stopped: a Ctrl-Z typed before the release
//! stops them for real, and the release leaves them stopped.

use crate::layout::*;
use crate::proc::Proc;
use crate::signal;
use crate::syscall::RESUME;
use crate::wait::{child, drives_any};
use crate::word::Word;

/// A new process `c` of process `par` (spawn): the group par chose.
pub fn join(c: Proc, par: Proc) {
    let g = match par.get(PCB_CPGRP) {
        0 => par.get(PCB_PGRP),
        1 => c.pid(),
        k => k - 2,
    };
    c.set(PCB_PGRP, g);
    if par.get(PCB_CHELD) != 0 {
        // Held before its first instruction: it parks on the way.
        c.set(PCB_HELD, 1);
        c.set(PCB_SIGNOTE, 1);
    }
}

/// Whether process `q` descends from process `a` (a itself not).
fn descends(q: Proc, a: Word) -> bool {
    let mut x = q.get(PCB_PARENT);
    for _ in 0..NPROC {
        if x < 0 || x >= NPROC {
            return false;
        }
        if x == a {
            return true;
        }
        x = Proc::of(x).get(PCB_PARENT);
    }
    false
}

/// Each process (not thread) that has not ended, in group `g`.
fn members(g: Word) -> impl Iterator<Item = Proc> {
    Proc::table().filter(move |&q| {
        !q.is(ST_EXITED) && !q.is(ST_ZOMBIE) && !q.is_thread() && q.get(PCB_PGRP) == g
    })
}

/// Whether process `me` may name group `g`: it is in it, or one of its
/// descendants is.
fn may_join(me: Proc, g: Word) -> bool {
    (0..NPROC).contains(&g) && members(g).any(|q| q == me || descends(q, me.pid()))
}

/// setpgrp(pid, pgrp).
pub fn sys_setpgrp(p: Proc) -> i32 {
    let r = setpgrp(p);
    p.set(PCB_A0, r);
    RESUME
}

fn setpgrp(p: Proc) -> Word {
    let me = p.space();
    let (pid, g) = (p.get(PCB_A1), p.get(PCB_A2));
    if pid == PGRP_RELEASE {
        if !(0..NPROC).contains(&g) {
            return E_INVAL;
        }
        let me = me.pid();
        for q in members(g) {
            if descends(q, me) && q.get(PCB_HELD) != 0 {
                q.set(PCB_HELD, 0);
                signal::unpark(q);
            }
        }
        return 0;
    }
    if pid == PGRP_CHILDREN {
        let held = p.get(PCB_A3);
        if held != 0 && held != 1 {
            return E_INVAL;
        }
        let code = match g {
            PGRP_SAME => 0,
            PGRP_NEW => 1,
            g if may_join(me, g) => g + 2,
            g if (0..NPROC).contains(&g) => return E_PERM,
            _ => return E_INVAL,
        };
        me.set(PCB_CPGRP, code);
        me.set(PCB_CHELD, held);
        return 0;
    }
    let target = if pid == FOR_SELF || pid == me.pid() {
        me
    } else {
        match child(pid, me.pid()) {
            Ok(c) if !c.is(ST_ZOMBIE) => c,
            Ok(_) => return E_NOCHILD,
            Err(e) => return e,
        }
    };
    let g = if g == PGRP_NEW || g == target.pid() {
        target.pid()
    } else if may_join(me, g) {
        g
    } else if (0..NPROC).contains(&g) {
        return E_PERM;
    } else {
        return E_INVAL;
    };
    target.set(PCB_PGRP, g);
    0
}

/// getpgrp(pid).
pub fn sys_getpgrp(p: Proc) -> i32 {
    let pid = p.get(PCB_A1);
    let r = if pid == FOR_SELF {
        p.space().get(PCB_PGRP)
    } else {
        match Proc::alive(pid) {
            Some(q) => q.space().get(PCB_PGRP),
            None => E_NOPROC,
        }
    };
    p.set(PCB_A0, r);
    RESUME
}

/// killpg(pgrp, for, sig).
pub fn sys_killpg(p: Proc) -> i32 {
    let r = killpg(p);
    p.set(PCB_A0, r);
    RESUME
}

fn killpg(p: Proc) -> Word {
    let (g, on_behalf, sig) = (p.get(PCB_A1), p.get(PCB_A2), p.get(PCB_A3));
    if !(0..NSIG).contains(&sig) || !(0..NPROC).contains(&g) {
        return E_INVAL;
    }
    // Whose descendants it reaches: None for any process but init.
    let root = if on_behalf == KILL_ANY {
        None
    } else if on_behalf == FOR_SELF {
        Some(p.space().pid())
    } else if !drives_any(p) {
        return E_PERM;
    } else if (0..NPROC).contains(&on_behalf) {
        Some(on_behalf)
    } else {
        return E_INVAL;
    };
    let mut found = false;
    let mut r = 0;
    for q in members(g) {
        let reach = match root {
            None => q != Proc::of(0), // init, which the rest needs
            Some(a) => descends(q, a),
        };
        if !reach {
            continue;
        }
        found = true;
        if sig != 0 {
            match signal::post(q, sig) {
                KILL_STOPPED => r = KILL_STOPPED,
                KILL_CAUGHT if r == 0 => r = KILL_CAUGHT,
                _ => {}
            }
        }
    }
    if found { r } else { E_NOPROC }
}

/// Process `c` has just stopped by signal `sig`: a thread of its parent
/// waiting for it with WAIT_UNTRACED hears so now, else a later waitpid
/// will (PCB_STOPWAIT); the parent is sent SIGCHLD.
pub fn stopped(c: Proc, sig: Word) {
    let parent = c.get(PCB_PARENT);
    if !(0..NPROC).contains(&parent) {
        return;
    }
    let pid = c.pid();
    let waiter = Proc::table().find(|q| {
        q.is(ST_WAIT)
            && q.get(PCB_SPACE) == parent
            && q.get(PCB_A1) == pid
            && q.get(PCB_A0) == SYS_WAITPID
            && q.get(PCB_A2) == WAIT_UNTRACED
    });
    if let Some(w) = waiter {
        w.set(PCB_A0, WAIT_STOPPED);
        w.set(PCB_A1, sig);
        w.ready();
        c.set(PCB_STOPWAIT, 0);
    }
    signal::post(Proc::of(parent), SIGCHLD);
}

/// Process `q` has lost its parent (wait::bury): if it is stopped,
/// nobody is left to set it going, so it is sent SIGHUP, which ends it
/// unless it catches or ignores it, and SIGCONT, as Unix does to a
/// stopped group its session leaves.
pub fn orphaned(q: Proc) {
    if q.get(PCB_STOP) != 0 {
        signal::post(q, SIGHUP);
        signal::post(q, SIGCONT);
    }
}
