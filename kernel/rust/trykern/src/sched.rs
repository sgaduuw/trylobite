//! Round-robin scheduling, under the kernel lock: which process a hart
//! runs next, the sleepers and alarms the clock wakes, and what to do
//! when nobody is ready. kernel/sched.s keeps what touches the hart
//! itself: leaving, idling with wfi and the lock, and halting.

use crate::kdata::{self, read, write};
use crate::layout::*;
use crate::proc::Proc;
use crate::word::{Word, load, store, time};

/// pick: the next ready process after `cur`, any record: `cur`'s turn
/// last, made ST_RUNNING; or null when none is ready (rk_stuck says
/// what then).
#[unsafe(no_mangle)]
pub extern "C" fn rk_pick(cur: *mut u8) -> *mut u8 {
    // Only once the earliest time one waits for has come: a scan of the
    // table on every switch costs a quantum's worth of steps.
    let now = time();
    if read::sleepers() != 0 && now >= read::next_wake() {
        wake_sleepers();
    }
    if now >= read::next_load() {
        sample_load(now);
    }
    // nready counts the ready: with none, or with only cur, no walk.
    let n = read::nready();
    if n == 0 {
        return core::ptr::null_mut();
    }
    write::nready(n - 1);
    let cur = Proc(cur);
    if n == 1 && cur.is(ST_READY) {
        cur.set(PCB_STATE, ST_RUNNING);
        return cur.0;
    }
    // The records after cur, then those up to cur: two plain walks, as a
    // wrapping one costs twice the steps a slot, on every switch. One is
    // ready, as nready counts.
    let (base, end) = Proc::bounds();
    let after = cur.at(PCB_SIZE);
    let mut q = first_ready(after, end);
    if q.is_null() {
        q = first_ready(base, after);
    }
    if q.is_null() {
        write::nready(0); // never so, while nready counts right
        return q;
    }
    Proc(q).set(PCB_STATE, ST_RUNNING);
    q
}

/// Fold the processes ready or running into the load averages, once
/// for each LOAD_PERIOD since the last sample (Unix's calc_load, in
/// LOAD_ONE parts). A busy hart picks every quantum, so periods with no
/// pick at all were ones every hart idled through, with nothing to run:
/// they count as 0, and only the last as what is runnable now. Rounding
/// up while an average climbs lets it reach a steady load rather than
/// stop short of it. The new average is the old moved (n - old) *
/// (LOAD_ONE - e) / LOAD_ONE, which fits an i32 (at most NPROC loads
/// times 1,574): a 64-bit division is a helper of thousands of steps,
/// taken with the kernel lock held.
#[cold]
fn sample_load(now: Word) {
    let one = LOAD_ONE as i32;
    let runnable = Proc::table()
        .filter(|q| q.is(ST_READY) || q.is(ST_RUNNING))
        .count() as i32
        * one;
    let mut due = read::next_load();
    let loads = kdata::load_avg_base();
    while due <= now {
        due += LOAD_PERIOD;
        let n = if due > now { runnable } else { 0 };
        for (k, e) in [LOAD_EXP1, LOAD_EXP5, LOAD_EXP15].into_iter().enumerate() {
            let at = loads.wrapping_offset(3 * k as isize);
            let old = load(at) as i32;
            let d = (n - old) * (one - e as i32);
            // Up for a climb, down for a fall: floor((old * e + n * (one
            // - e) + up) / one), as calc_load has it.
            let step = if d > 0 { (d + one - 1) / one } else { -((one - 1 - d) / one) };
            store(at, (old + step) as Word);
        }
    }
    write::next_load(due);
}

/// The first ready record from `at` up to `end`, or null.
#[inline(always)]
fn first_ready(mut at: *mut u8, end: *mut u8) -> *mut u8 {
    while at < end {
        if Proc(at).is(ST_READY) {
            return at;
        }
        at = at.wrapping_offset(PCB_SIZE as isize);
    }
    core::ptr::null_mut()
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
        [ST_RECV, ST_CALL, ST_REPLY, ST_LOOKUP, ST_FUTEX, ST_JOIN]
            .iter()
            .any(|&t| s == t as i32)
    });
    if stuck { 2 } else { 1 }
}
