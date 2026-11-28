//! System calls: which routine each number goes to, and the few small
//! calls with no subsystem of their own. ktrap hands the caller's record
//! to `rk_syscall` (kernel/syscall.s); the routine leaves the result in
//! the record's saved a0 and says what happens next.

use crate::console::{putc, putn, puts, putw};
use crate::layout::*;
use crate::mem::{page_left, user_at};
use crate::proc::Proc;
use crate::word::{Word, addr, load_at};
use crate::{desc, devices, info, ipc, mm, names, procinfo, wait};

/// The caller goes on (resume).
pub const RESUME: i32 = 0;
/// The caller sleeps or yields: another process runs (schedule).
pub const SCHEDULE: i32 = 1;
/// The caller has ended: its pages go and it is buried (release).
pub const RELEASE: i32 = 2;

unsafe extern "C" {
    /// kernel/console.s: print the string at a0, at most a1 trytes of it;
    /// 1 if it ended with its 0.
    fn kputs_upto(s: *const u8, n: i32) -> i32;
    static msg_proc: u8;
    static msg_exited: u8;
}

/// Run the system call of process `p`: its number in the saved a0, its
/// arguments in a1 to a5 (kernel/syscall.s, on_syscall and retry).
#[unsafe(no_mangle)]
pub extern "C" fn rk_syscall(p: *mut u8) -> i32 {
    let p = Proc(p);
    let n = p.get(PCB_A0);
    if n < 0 || n >= CALLS.len() as Word {
        return nocall(p);
    }
    CALLS[n as usize](p)
}

/// Each call's routine, by its number (SYS_ in include/layout.s): one
/// indirect call, where a chain of tests took 40 for the last.
static CALLS: [fn(Proc) -> i32; SYS_CLOCK as usize + 1] = [
    sys_putc,     // 0
    sys_send,     // 1
    sys_recv,     // 2
    sys_yield_,   // 3
    sys_exit,     // 4
    sys_getpid,   // 5
    sys_puts,     // 6
    sys_spawn,    // 7
    sys_hart,     // 8
    nocall,       // 9, not a call
    sys_wait,     // 10
    nocall,       // 11, not a call
    nocall,       // 12, not a call
    sys_kill,     // 13
    nocall,       // 14, not a call
    sys_spawnw,   // 15
    sys_close,    // 16
    sys_give,     // 17
    sys_dup2,     // 18
    sys_iocall,   // 19
    sys_read,     // 20
    sys_write,    // 21
    sys_fdflags,  // 22
    sys_call,     // 23
    sys_receive,  // 24
    sys_reply,    // 25
    sys_copyin,   // 26
    sys_copyout,  // 27
    sys_register, // 28
    sys_lookup,   // 29
    sys_window,   // 30
    sys_drive,    // 31
    sys_arm,      // 32
    sys_phys,     // 33
    sys_log,      // 34
    sys_info,     // 35
    sys_proc,     // 36
    sys_name,     // 37
    sys_sleep,    // 38
    sys_notify,   // 39
    sys_alarm,    // 40
    sys_brk,      // 41
    sys_clock,    // 42
];

const _: () =
    assert!(SYS_PUTC == 0 && SYS_SEND == 1 && SYS_BRK == 41 && SYS_CLOCK == 42 && SYS_CALL == 23 && SYS_RECEIVE == 24);

/// A number that names no call.
fn nocall(p: Proc) -> i32 {
    done(p, E_NOCALL)
}

fn sys_putc(p: Proc) -> i32 {
    {
        putc(p.get(PCB_A1) as i32);
        done(p, 0)
    }
}

fn sys_send(p: Proc) -> i32 {
    ipc::rk_sys_send(p.0)
}

fn sys_recv(p: Proc) -> i32 {
    ipc::rk_sys_recv(p.0)
}

fn sys_yield_(p: Proc) -> i32 {
    {
        p.set(PCB_A0, 0);
        SCHEDULE
    }
}

fn sys_exit(p: Proc) -> i32 {
    exit(p)
}

fn sys_getpid(p: Proc) -> i32 {
    done(p, p.pid())
}

fn sys_puts(p: Proc) -> i32 {
    {
        let r = puts_string(p);
        done(p, r)
    }
}

fn sys_spawn(p: Proc) -> i32 {
    {
        mm::rk_sys_spawn(p.0);
        RESUME
    }
}

fn sys_hart(p: Proc) -> i32 {
    done(p, p.get(PCB_HART))
}

fn sys_wait(p: Proc) -> i32 {
    wait::rk_sys_wait(p.0)
}

fn sys_kill(p: Proc) -> i32 {
    {
        wait::rk_sys_kill(p.0);
        RESUME
    }
}

fn sys_spawnw(p: Proc) -> i32 {
    {
        mm::rk_sys_spawnw(p.0);
        RESUME
    }
}

fn sys_close(p: Proc) -> i32 {
    {
        desc::rk_sys_close(p.0);
        RESUME
    }
}

fn sys_give(p: Proc) -> i32 {
    {
        desc::rk_sys_give(p.0);
        RESUME
    }
}

fn sys_dup2(p: Proc) -> i32 {
    {
        desc::rk_sys_dup2(p.0);
        RESUME
    }
}

fn sys_iocall(p: Proc) -> i32 {
    desc::rk_sys_iocall(p.0)
}

fn sys_read(p: Proc) -> i32 {
    desc::rk_sys_read(p.0)
}

fn sys_write(p: Proc) -> i32 {
    desc::rk_sys_write(p.0)
}

fn sys_fdflags(p: Proc) -> i32 {
    {
        desc::rk_sys_fdflags(p.0);
        RESUME
    }
}

fn sys_call(p: Proc) -> i32 {
    ipc::rk_sys_call(p.0)
}

fn sys_receive(p: Proc) -> i32 {
    ipc::rk_sys_receive(p.0)
}

fn sys_reply(p: Proc) -> i32 {
    ipc::rk_sys_reply(p.0)
}

fn sys_copyin(p: Proc) -> i32 {
    ipc::rk_sys_copyin(p.0)
}

fn sys_copyout(p: Proc) -> i32 {
    ipc::rk_sys_copyout(p.0)
}

fn sys_register(p: Proc) -> i32 {
    {
        names::rk_sys_register(p.0);
        RESUME
    }
}

fn sys_lookup(p: Proc) -> i32 {
    names::rk_sys_lookup(p.0)
}

fn sys_window(p: Proc) -> i32 {
    {
        mm::rk_sys_window(p.0);
        RESUME
    }
}

fn sys_drive(p: Proc) -> i32 {
    {
        devices::rk_sys_drive(p.0);
        RESUME
    }
}

fn sys_arm(p: Proc) -> i32 {
    {
        devices::rk_sys_arm(p.0);
        RESUME
    }
}

fn sys_phys(p: Proc) -> i32 {
    {
        mm::rk_sys_phys(p.0);
        RESUME
    }
}

fn sys_log(p: Proc) -> i32 {
    {
        info::rk_sys_log(p.0);
        RESUME
    }
}

fn sys_info(p: Proc) -> i32 {
    {
        info::rk_sys_info(p.0);
        RESUME
    }
}

fn sys_proc(p: Proc) -> i32 {
    {
        procinfo::rk_sys_proc(p.0);
        RESUME
    }
}

fn sys_name(p: Proc) -> i32 {
    {
        procinfo::rk_sys_name(p.0);
        RESUME
    }
}

fn sys_sleep(p: Proc) -> i32 {
    procinfo::rk_sys_sleep(p.0)
}

fn sys_notify(p: Proc) -> i32 {
    ipc::rk_sys_notify(p.0)
}

fn sys_alarm(p: Proc) -> i32 {
    {
        procinfo::rk_sys_alarm(p.0);
        RESUME
    }
}

fn sys_brk(p: Proc) -> i32 {
    {
        mm::rk_sys_brk(p.0);
        RESUME
    }
}

/// clock(): the real-time clock's seconds in a0 and microseconds in a1.
/// Reading the seconds latches the microseconds for this hart, so the
/// two are one moment: nothing else runs on this hart between the loads.
fn sys_clock(p: Proc) -> i32 {
    let power = addr(V_POWER);
    let seconds = load_at(power, POWER_CLOCK);
    p.set(PCB_A1, load_at(power, POWER_CLOCK_US));
    done(p, seconds)
}

/// The caller's result is `r`, and it goes on.
fn done(p: Proc, r: Word) -> i32 {
    p.set(PCB_A0, r);
    RESUME
}

/// puts(address): print a 0-ended string from the caller's memory in
/// one go, so preemption cannot split it: its page, or a block window it
/// has. The kernel reads it through the direct map, so a process cannot
/// make it print kernel memory, or fault inside it; the string stops at
/// the end of what the process has mapped. E_RANGE if it has nothing
/// there at all.
fn puts_string(p: Proc) -> Word {
    let mut at = p.get(PCB_A1);
    let mut first = true;
    loop {
        let k = user_at(p, at);
        if k.is_null() {
            return if first { E_RANGE } else { 0 };
        }
        let n = page_left(at);
        if unsafe { kputs_upto(k, n as i32) } != 0 {
            return 0;
        }
        at += n; // on into the next page, if mapped
        first = false;
    }
}

/// exit(code): say so, and end with WAIT_EXITED and the code (saved a1)
/// for the parent's wait.
fn exit(p: Proc) -> i32 {
    puts(unsafe { &raw const msg_proc });
    putn(p.pid() as i32);
    puts(unsafe { &raw const msg_exited });
    putw(p.get(PCB_A1));
    putc(b'\n' as i32);
    p.set(PCB_A0, WAIT_EXITED);
    RELEASE
}
