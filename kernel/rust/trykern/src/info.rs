//! What the kernel tells about itself, for system tools: its log
//! (bin/dmesg) and a summary of the machine and its use (bin/uname,
//! bin/uptime, bin/free). The kernel only reports; the tools format.
//! kernel/info.s calls these with the caller's record.

use crate::harts::harts_present;
use crate::kdata::{self, read};
use crate::layout::*;
use crate::mem::uva;
use crate::proc::Proc;
use crate::word::{Word, addr, store_at, time};

/// log(buffer, n, from): copy at most n code points of the log, from the
/// from-th the kernel ever printed, to buffer: a0 = how many, a1 = where
/// the next read starts. A reader that fell behind starts at the oldest
/// the log still keeps; one ahead of the log gets 0. A buffer that runs
/// off the end of its page gets as many as fit.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_log(p: *mut u8) {
    let p = Proc(p);
    let n = log(p);
    p.set(PCB_A0, n);
}

fn log(p: Proc) -> Word {
    let n = p.get(PCB_A2);
    if n < 0 {
        return E_INVAL;
    }
    let printed = read::log_pos(); // code points ever printed
    let from = p.get(PCB_A3).max(printed - LOG_SIZE).max(0).min(printed);
    let mut count = (printed - from).min(n);
    if count > 0 {
        let Some((buffer, left)) = uva(p, p.get(PCB_A1)) else {
            return E_FAULT;
        };
        count = count.min(left); // as many as fit in its page
        // The log is a ring of LOG_SIZE trytes: at most two runs.
        let base = addr(read::log_base());
        let start = from % LOG_SIZE;
        let first = count.min(LOG_SIZE - start);
        unsafe {
            copy(base.wrapping_offset(start as isize), buffer, first);
            copy(base, buffer.wrapping_offset(first as isize), count - first);
        }
    }
    p.set(PCB_A1, from + count);
    count
}

/// Copy `n` trytes as they are (kernel/rt.s's memcpy).
unsafe fn copy(from: *const u8, to: *mut u8, n: Word) {
    if n > 0 {
        unsafe { core::ptr::copy_nonoverlapping(from, to, n as usize) }
    }
}

/// info(buffer): the SI_ words at buffer: the clock, memory, the process
/// table and harts, and the kernel's version.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_info(p: *mut u8) {
    let p = Proc(p);
    let r = info(p);
    p.set(PCB_A0, r);
}

fn info(p: Proc) -> Word {
    let at = p.get(PCB_A1);
    if at % 3 != 0 {
        return E_FAULT; // words must be aligned
    }
    let Some((first, left)) = uva(p, at + SI_TIME - 1) else {
        return E_FAULT;
    };
    if left < SYSINFO {
        return E_FAULT; // not all in one page
    }
    // The buffer, as its words see it.
    let b = first.wrapping_offset((1 - SI_TIME) as isize);
    store_at(b, SI_TIME, time());
    store_at(b, SI_TICKS, read::ticks());
    store_at(b, SI_PAGES, read::ram_pages());
    store_at(b, SI_FREE, read::free_count());
    store_at(b, SI_NPROC, NPROC);
    let in_use = Proc::table().filter(|q| q.state() != 0).count();
    store_at(b, SI_PROCS, in_use as Word);
    store_at(b, SI_HARTS, harts_present() as Word);
    // The version, 0-padded; the last is always the end.
    let version = kdata::version();
    let release = b.wrapping_offset(SI_RELEASE as isize);
    let mut ended = false;
    for i in 0..RELEASE_MAX + 1 {
        let c = if ended || i == RELEASE_MAX {
            0
        } else {
            unsafe { *version.wrapping_offset(i as isize) }
        };
        ended |= c == 0;
        unsafe { *release.wrapping_offset(i as isize) = c };
    }
    0
}
