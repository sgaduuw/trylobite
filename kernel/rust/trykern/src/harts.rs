//! Harts: starting the others at boot and as they are plugged in, waking
//! one that waits for work, and asking one to go when the platform says.
//!
//! Hot-plug events reach hart 0, the controller's event hart, which can
//! never be removed. An added hart in the middle nine is started. A hart
//! asked to go is marked leaving; at its next scheduling point (pick) it
//! puts its process back, gives the lock up and stops itself (hart_leave
//! in kernel/harts.s), and the platform removes it. Hart h uses index
//! h + HART_MAX in per-hart tables (idle_harts, leaving).

use crate::console::{putn, puts};
use crate::kdata;
use crate::layout::*;
use crate::word::{Word, addr, load, load_at, load_small_at, store, store_at};

unsafe extern "C" {
    /// firmware/boot.s: where every hart starts, untranslated.
    static boot: u8;
    /// kernel/entry.s: where a hart the kernel starts enters it.
    static ksecondary: u8;
    static msg_hart: u8;
    static msg_joined: u8;
}

/// Hart `h`'s slot at the hart controller.
fn slot(h: i32) -> *mut u8 {
    addr(V_HARTS).wrapping_offset(27 * h as isize)
}

/// Hart `h`'s entry in a per-hart table of words.
fn entry(table: *mut u8, h: i32) -> *mut u8 {
    table.wrapping_offset(3 * (h + HART_MAX as i32) as isize)
}

/// Whether hart `h` is one of the middle nine, which the kernel runs on.
fn in_middle(h: i32) -> bool {
    h >= -(HART_MAX as i32) && h <= HART_MAX as i32
}

/// How many of the middle nine harts are present (the boot report,
/// info).
pub fn harts_present() -> i32 {
    let mut n = 0;
    for h in -(HART_MAX as i32)..HART_MAX as i32 + 1 {
        if load_small_at(slot(h), HC_STATE) >= 0 {
            n += 1;
        }
    }
    n
}

/// Start hart `h` if it is in the middle nine, present and stopped. It
/// enters the firmware like hart 0, with a0 = ksecondary, and waits for
/// the kernel lock there. Whether it was started.
fn start_hart(h: i32) -> bool {
    if !in_middle(h) {
        return false;
    }
    let s = slot(h);
    if load_at(s, HC_STATE) != 0 {
        return false; // absent, or running already
    }
    store_at(s, HC_START_PC, unsafe { &raw const boot } as isize as Word);
    store_at(s, HC_START_ARG, unsafe { &raw const ksecondary } as isize
        as Word);
    // A fresh start: not leaving, whatever an earlier life of the hart
    // was asked.
    store(entry(kdata::leaving_base(), h), 0);
    store_at(s, HC_CONTROL, 1);
    true
}

/// Start every other hart of the middle nine that is present (boot).
#[unsafe(no_mangle)]
pub extern "C" fn rk_start_harts() {
    for h in -(HART_MAX as i32)..HART_MAX as i32 + 1 {
        start_hart(h); // hart 0 is running: left alone
    }
}

/// Take every queued hot-plug event and act on it. Only hart 0 receives
/// them. An event is 3 × the hart + its kind in the lowest trit: −1
/// removed, else added.
#[unsafe(no_mangle)]
pub extern "C" fn rk_hotplug_events() {
    loop {
        let e = load_small_at(addr(V_HART), HC_EVENT);
        if e == 0 {
            break;
        }
        let kind = match e % 3 {
            2 => -1,
            -2 => 1,
            k => k,
        };
        let h = (e - kind) / 3;
        if kind < 0 {
            ask_to_leave(h);
        } else if start_hart(h) {
            // Outside the middle nine, or started already, it says nothing.
            puts(unsafe { &raw const msg_hart });
            putn(h);
            puts(unsafe { &raw const msg_joined });
        }
    }
}

/// Mark hart `h` leaving, and wake it if it waits for work, so it gets
/// to pick and stops. A hart outside the middle nine was never started,
/// and the platform removes a stopped hart by itself.
fn ask_to_leave(h: i32) {
    if !in_middle(h) {
        return;
    }
    store(entry(kdata::leaving_base(), h), 1);
    let idle = entry(kdata::idle_harts_base(), h);
    if load(idle) != 0 {
        store(idle, 0);
        store_at(slot(h), HC_SEND, 1);
    }
}

/// Something became ready to run: ring the doorbell of one hart waiting
/// for work, if any, and take it off the waiting list so the next
/// wake-up goes to another.
pub fn wake_one() {
    // A pointer walk, the hart worked out only for the one it finds:
    // wake_one runs whenever a process becomes ready.
    let base = kdata::idle_harts_base();
    let end = base.wrapping_offset(3 * NHART as isize);
    let mut idle = base;
    while idle < end {
        if load_small_at(idle, 0) != 0 {
            store(idle, 0);
            let k = (idle as isize - base as isize) as i32 / 3;
            store_at(slot(k - HART_MAX as i32), HC_SEND, 1);
            return;
        }
        idle = idle.wrapping_offset(3);
    }
    // Every hart is busy.
}

/// wake_one for kernel/harts.s (hart_leave hands its process on).
#[unsafe(no_mangle)]
pub extern "C" fn rk_wake_one() {
    wake_one()
}
