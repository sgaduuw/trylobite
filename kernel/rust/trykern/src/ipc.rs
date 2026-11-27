//! Messages: send and recv's one-word mailbox, and for servers call,
//! receive and reply, notify, and copying between a server and a process
//! whose call it holds (docs/kernel.md, "Messages for servers").
//!
//! A call is four words, from the caller's a2..a5; the caller sleeps
//! until the server replies with four words of its own, which its call
//! returns in a0..a3. The server takes calls one at a time with receive,
//! which says who sent each; while it holds a call (the caller is
//! ST_REPLY, with the server as its PCB_PEER), it may copy to and from
//! the caller's memory with copyin and copyout.
//!
//! A process that has called receive once is told of every process that
//! ends, by a message from FROM_KERNEL, before any call that came later,
//! so a server can drop what it kept for a process before a new process
//! with the same number reaches it. A process that ends while others
//! call it fails their calls with E_NOPROC.
//!
//! A server asleep in receive is woken by setting PCB_RETRY (rouse,
//! `Proc::retry_if`): it runs receive again and finds the call or the
//! notice itself.

use crate::layout::*;
use crate::mem::{page_left, user_at};
use crate::proc::Proc;
use crate::trytes;
use crate::word::{Word, load_small_at};

/// What a system call's stub does next: resume the caller, or schedule
/// (it sleeps).
pub const RESUME: i32 = 0;
pub const SCHEDULE: i32 = 1;

/// send(pid, value): deliver straight to a receiver waiting in recv, else
/// leave the value in its one-word mailbox, else report the mailbox full.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_send(p: *mut u8) -> i32 {
    let p = Proc(p);
    let value = p.get(PCB_A2);
    let r = match Proc::alive(p.get(PCB_A1)) {
        None => E_NOPROC,
        Some(q) if q.is(ST_RECV) => {
            q.set(PCB_A0, value); // its recv returns the value
            q.ready();
            0
        }
        Some(q) if q.get(PCB_FULL) != 0 => E_FULL,
        Some(q) => {
            q.set(PCB_MAIL, value);
            q.set(PCB_FULL, 1);
            0
        }
    };
    done(p, r)
}

/// recv(): take the waiting message, or sleep until send delivers one.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_recv(p: *mut u8) -> i32 {
    let p = Proc(p);
    if p.get(PCB_FULL) == 0 {
        p.set(PCB_STATE, ST_RECV);
        return SCHEDULE;
    }
    p.set(PCB_FULL, 0);
    done(p, p.get(PCB_MAIL))
}

/// call(pid, w1, w2, w3, w4). A negative w1 is an IO_ operation, which
/// only a descriptor call (desc.rs) sends, through `call`.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_call(p: *mut u8) -> i32 {
    let p = Proc(p);
    if p.get(PCB_A2) < 0 {
        return done(p, E_INVAL);
    }
    call(p)
}

/// The caller's call to the server its saved a1 names, with its saved
/// a2..a5: it sleeps in ST_CALL until the server replies.
pub fn call(p: Proc) -> i32 {
    let pid = p.get(PCB_A1);
    let Some(q) = Proc::alive(pid) else {
        return done(p, E_NOPROC);
    };
    if q == p {
        return done(p, E_SELF);
    }
    p.set(PCB_PEER, pid);
    p.set(PCB_STATE, ST_CALL);
    q.retry_if(ST_RECEIVE);
    SCHEDULE
}

/// receive(): a notice first (an interrupt's, then its alarm's, then a
/// closed handle's, then a notification's, then an ending's), else the
/// next caller after the last one taken, else sleep until rouse wakes
/// it.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_receive(p: *mut u8) -> i32 {
    let p = Proc(p);
    p.set(PCB_SERVES, 1);
    // Results here are i32s with NONE for none, rather than an Option of
    // a word, which comes back through memory a limb at a time.
    let src = first_set(p.at(PCB_IRQS), NSRC as i32);
    if src != NONE {
        return notice(p, NOTE_IRQ, src as Word + 1);
    }
    if p.get(PCB_RANG) != 0 {
        p.set(PCB_RANG, 0);
        return notice(p, NOTE_ALARM, 0);
    }
    let h = first_flag(p.at(PCB_CLOSED), NHANDLE as i32);
    if h != NONE {
        return notice(p, NOTE_CLOSED, h as Word);
    }
    let pid = first_flag(p.at(PCB_SIGNALS), NPROC as i32);
    if pid != NONE {
        return notice(p, NOTE_SIGNAL, pid as Word);
    }
    let pid = first_flag(p.at(PCB_NOTES), NPROC as i32);
    if pid != NONE {
        return notice(p, NOTE_ENDED, pid as Word);
    }
    // The next caller after the one it took last, that one's turn last:
    // two plain walks, as in sched::rk_pick.
    let me = p.pid();
    let (base, end) = Proc::bounds();
    let after = Proc::of(p.get(PCB_TURN)).at(PCB_SIZE);
    let mut c = first_caller(after, end, me);
    if c.is_null() {
        c = first_caller(base, after, me);
    }
    if c.is_null() {
        p.set(PCB_STATE, ST_RECEIVE);
        return SCHEDULE;
    }
    let c = Proc(c);
    p.set(PCB_TURN, c.pid());
    c.set(PCB_STATE, ST_REPLY);
    p.set(PCB_A1, c.get(PCB_A2));
    p.set(PCB_A2, c.get(PCB_A3));
    p.set(PCB_A3, c.get(PCB_A4));
    p.set(PCB_A4, c.get(PCB_A5));
    done(p, c.pid())
}

/// No flag set (first_set, first_flag).
const NONE: i32 = -1;

/// The first record from `at` up to `end` calling process `me`, or null.
#[inline(always)]
fn first_caller(mut at: *mut u8, end: *mut u8, me: Word) -> *mut u8 {
    while at < end {
        let c = Proc(at);
        if c.is(ST_CALL) && c.get(PCB_PEER) == me {
            return at;
        }
        at = at.wrapping_offset(PCB_SIZE as isize);
    }
    core::ptr::null_mut()
}

/// Which of the `n` flag trytes at `at` is the first set, cleared; NONE.
#[inline(always)]
fn first_set(at: *mut u8, n: i32) -> i32 {
    let mut k = 0;
    while k < n {
        let t = at.wrapping_offset(k as isize);
        if trytes::get(t) != 0 {
            trytes::put(t, 0);
            return k;
        }
        k += 1;
    }
    NONE
}

/// first_set for `n` flags, a multiple of 3, from `at`, where `at + 1`
/// is a word's first tryte, so that a word at a time tells whether any
/// of its three is (include/layout.s asserts both). Each flag is 0 or 1,
/// so a word of them fits an i32.
#[inline(always)]
fn first_flag(at: *mut u8, n: i32) -> i32 {
    let mut w = at;
    let end = at.wrapping_offset(n as isize);
    while w < end {
        if load_small_at(w, 1) != 0 {
            let k = (w as isize - at as isize) as i32;
            return k + first_set(w, 3);
        }
        w = w.wrapping_offset(3);
    }
    NONE
}

/// receive's result for a notice: what it is, and of which.
fn notice(p: Proc, what: Word, of: Word) -> i32 {
    p.set(PCB_A1, what);
    p.set(PCB_A2, of);
    done(p, FROM_KERNEL)
}

/// reply(pid, w1, w2, w3, w4): the caller's call returns them.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_reply(p: *mut u8) -> i32 {
    let p = Proc(p);
    let Some(c) = client_of(p, p.get(PCB_A1)) else {
        return done(p, E_NOPROC);
    };
    c.set(PCB_A0, p.get(PCB_A2));
    c.set(PCB_A1, p.get(PCB_A3));
    c.set(PCB_A2, p.get(PCB_A4));
    c.set(PCB_A3, p.get(PCB_A5));
    c.ready();
    done(p, 0)
}

/// copyin(pid, from, to, n): from the caller's memory to the server's.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_copyin(p: *mut u8) -> i32 {
    let p = Proc(p);
    let r = client_of(p, p.get(PCB_A1)).map_or(E_NOPROC, |c| {
        copy_mem(c, p.get(PCB_A2), p, p.get(PCB_A3), p.get(PCB_A4))
    });
    done(p, r)
}

/// copyout(pid, from, to, n): from the server's memory to the caller's.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_copyout(p: *mut u8) -> i32 {
    let p = Proc(p);
    let r = client_of(p, p.get(PCB_A1)).map_or(E_NOPROC, |c| {
        copy_mem(p, p.get(PCB_A2), c, p.get(PCB_A3), p.get(PCB_A4))
    });
    done(p, r)
}

/// notify(pid): mark the caller in process pid's PCB_SIGNALS and wake it
/// if it sleeps in receive. Nothing waits: a process may notify a server
/// it also calls, and the server may notify a process that is calling
/// it.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_notify(p: *mut u8) -> i32 {
    let p = Proc(p);
    let r = match Proc::alive(p.get(PCB_A1)) {
        None => E_NOPROC,
        Some(q) if q == p => E_SELF,
        Some(q) => {
            q.set_tryte(PCB_SIGNALS + p.pid(), 1);
            q.retry_if(ST_RECEIVE);
            0
        }
    };
    done(p, r)
}

/// The result of the caller's system call is `r`, and it goes on.
fn done(p: Proc, r: Word) -> i32 {
    p.set(PCB_A0, r);
    RESUME
}

/// Process `pid`, if it is alive and waiting for `p`'s reply (ST_REPLY,
/// its PCB_PEER `p`); else none, which is E_NOPROC. Waiting for a reply
/// it is alive, and its PCB_PEER a process number (call set it).
#[inline(always)]
pub fn client_of(p: Proc, pid: Word) -> Option<Proc> {
    if pid < 0 || pid >= NPROC {
        return None;
    }
    let c = Proc::of(pid);
    (c.is(ST_REPLY) && Proc::of(c.get(PCB_PEER)) == p).then_some(c)
}

/// Process `pid`, in `p`, has ended (bury). Tell every process that
/// receives, and its parent, whether it has received yet or not (so init
/// hears of a server that ends before init first receives), and fail the
/// calls made to it.
#[unsafe(no_mangle)]
pub extern "C" fn rk_ipc_ended(p: *mut u8, pid: i32) {
    let p = Proc(p);
    let pid = pid as Word;
    p.set(PCB_ALARM, 0); // nobody to ring for now
    let parent = p.get(PCB_PARENT);
    let parent = (parent >= 0).then(|| Proc::of(parent));
    for q in Proc::table() {
        if q == p || q.is(ST_EXITED) {
            continue;
        }
        if q.get(PCB_SERVES) != 0 || Some(q) == parent {
            q.set_tryte(PCB_NOTES + pid, 1);
            q.set_tryte(PCB_SIGNALS + pid, 0); // a notification from it is stale now
            q.retry_if(ST_RECEIVE);
        }
        if (q.is(ST_CALL) || q.is(ST_REPLY)) && q.get(PCB_PEER) == pid {
            q.set(PCB_A0, E_NOPROC); // its call fails
            q.ready();
        }
    }
}

/// Copy `n` trytes from `from` in process `src` to `to` in process
/// `dst`. It checks the whole of both ranges first, so it copies all or
/// nothing: 0, or E_FAULT.
pub fn copy_mem(src: Proc, from: Word, dst: Proc, to: Word, n: Word) -> Word {
    // Most copies are a few trytes, within a page on each side: one
    // look at each, then one copy.
    let (a, b) = (user_at(src, from), user_at(dst, to));
    if !a.is_null() && !b.is_null() && n >= 0 && n <= page_left(from).min(page_left(to)) {
        trytes::copy(a, b, n as usize);
        return 0;
    }
    if n < 0 || !each_chunk(src, from, dst, to, n, |_, _, _| ()) {
        return E_FAULT;
    }
    each_chunk(src, from, dst, to, n, |a, b, k| {
        trytes::copy(a, b, k as usize)
    });
    0
}

/// Call `f` with where each piece of the copy is in the kernel and its
/// length, a piece ending where either side's page does; false, having
/// stopped, at a tryte either process does not have.
fn each_chunk(
    src: Proc,
    mut from: Word,
    dst: Proc,
    mut to: Word,
    mut n: Word,
    mut f: impl FnMut(*mut u8, *mut u8, Word),
) -> bool {
    while n > 0 {
        let (a, b) = (user_at(src, from), user_at(dst, to));
        if a.is_null() || b.is_null() {
            return false;
        }
        let k = page_left(from).min(page_left(to)).min(n);
        f(a, b, k);
        from += k;
        to += k;
        n -= k;
    }
    true
}
