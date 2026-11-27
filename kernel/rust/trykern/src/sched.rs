//! Round-robin scheduling, under the kernel lock: which process a hart
//! runs next, the sleepers and alarms the clock wakes, and what to do
//! when nobody is ready. kernel/sched.s keeps what touches the hart
//! itself: leaving, idling with wfi and the lock, and halting.

use crate::kdata::{read, write};
use crate::layout::*;
use crate::proc::Proc;
use crate::word::{Word, time};

/// pick: the next ready process after `cur`, any record: `cur`'s turn
/// last, made ST_RUNNING; or null when none is ready (rk_stuck says
/// what then).
#[unsafe(no_mangle)]
pub extern "C" fn rk_pick(cur: *mut u8) -> *mut u8 {
    // Only once the earliest time one waits for has come: a scan of the
    // table on every switch costs a quantum's worth of steps.
    if read::sleepers() != 0 && time() >= read::next_wake() {
        wake_sleepers();
    }
    // The records after cur, then those up to cur: two plain walks, as a
    // wrapping one costs twice the steps a slot, on every switch.
    let (base, end) = Proc::bounds();
    let after = cur.wrapping_offset(PCB_SIZE as isize);
    first_ready(after, end)
        .or_else(|| first_ready(base, after))
        .map_or(core::ptr::null_mut(), |q| {
            q.set(PCB_STATE, ST_RUNNING);
            q.0
        })
}

/// The first ready record from `at` up to `end`.
#[inline(always)]
fn first_ready(mut at: *mut u8, end: *mut u8) -> Option<Proc> {
    while at < end {
        if Proc(at).is(ST_READY) {
            return Some(Proc(at));
        }
        at = at.wrapping_offset(PCB_SIZE as isize);
    }
    None
}

/// Make ready each sleeper whose time has come, and ring each alarm
/// whose time has come (its receive gives NOTE_ALARM); sleepers becomes
/// whether any still sleep or have an alarm set, and next_wake the
/// earliest time one waits for.
fn wake_sleepers() {
    let mut now = time();
    let mut any = false;
    for q in Proc::table() {
        let alarm = q.get(PCB_ALARM);
        if alarm != 0 {
            if alarm <= now {
                q.set(PCB_ALARM, 0); // it rings
                q.set(PCB_RANG, 1);
                q.rouse();
                now = time();
            } else {
                later(alarm, &mut any);
            }
        }
        if q.is(ST_SLEEP) {
            let until = q.get(PCB_A1);
            if until <= now {
                q.ready(); // an idle hart can run it
            } else {
                later(until, &mut any);
            }
        }
    }
    write::sleepers(any as Word);
}

/// The caller now sleeps or has an alarm, until `at`: sleepers says
/// so, and next_wake keeps the earliest time any waits for.
pub fn sleeps_until(at: Word) {
    let mut any = read::sleepers() != 0;
    later(at, &mut any);
    write::sleepers(1);
}

/// One still waits, until `at`: keep the earliest in next_wake.
fn later(at: Word, any: &mut bool) {
    if !*any || at < read::next_wake() {
        write::next_wake(at);
    }
    *any = true;
}

/// Nobody is ready: 0 to wait for work (idle), 1 when every process has
/// ended, 2 when some wait and nothing can wake them (a deadlock).
#[unsafe(no_mangle)]
pub extern "C" fn rk_stuck() -> i32 {
    // A process running on another hart can still send or spawn, and an
    // armed device can still wake its driver: wait for work. A device is
    // worth waiting for only while some process waits on something (a
    // call, a child, a name, a message): servers all asleep in receive
    // have nobody left to serve, so a network server listening for frames
    // does not keep the machine on by itself.
    if read::irq_armed() != 0 {
        let waits = Proc::table().any(|q| {
            let s = q.state();
            s < 0 && s != ST_RECEIVE as i32 && s != ST_ZOMBIE as i32
        });
        if waits {
            return 0;
        }
    }
    if read::sleepers() != 0 {
        return 0; // the clock will wake a sleeper
    }
    if Proc::table().any(|q| q.is(ST_RUNNING)) {
        return 0;
    }
    // Nothing runs anywhere. Someone still waiting means nobody will wake
    // them; a server asleep in receive is not stuck: it has nobody left
    // to serve.
    let stuck = Proc::table().any(|q| {
        let s = q.state();
        [ST_RECV, ST_CALL, ST_REPLY, ST_LOOKUP]
            .iter()
            .any(|&t| s == t as i32)
    });
    if stuck { 2 } else { 1 }
}
