//! Descriptors: a table in each process's record, turning read and write
//! on a number into calls to the server behind it. The kernel keeps only
//! the routing: which server, and the handle that server gave out. Only
//! the server puts a descriptor into a table (give), so a handle cannot be
//! forged; and since SYS_CALL refuses the IO_ operations, a server that
//! gets one knows the kernel brought it from a descriptor it gave. The
//! kernel tells the server when the last descriptor naming a handle goes,
//! so the server never has to know who holds its handles.
//!
//! A descriptor is DESC trytes of the record from PCB_DESCS, three words:
//! the server plus 1 (0: free), the handle, and its flags.

use crate::ipc;
use crate::layout::*;
use crate::proc::Proc;
use crate::word::{Word, load, load_at, store_at};

/// A descriptor, by address.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Desc(*mut u8);

impl Desc {
    /// Process `p`'s descriptor `fd`, which must be in range.
    fn of(p: Proc, fd: Word) -> Desc {
        Desc(p.at(PCB_DESCS + (fd as i32 * DESC as i32) as Word)) // 32-bit: no helper call
    }

    fn all(p: Proc) -> impl Iterator<Item = Desc> {
        (0..NDESC).map(move |fd| Desc::of(p, fd))
    }

    /// The server plus 1, or 0 when it names nothing.
    fn server(self) -> Word {
        load(self.0)
    }

    fn handle(self) -> Word {
        load_at(self.0, 3)
    }

    fn flags(self) -> Word {
        load_at(self.0, 6)
    }

    fn set(self, server: Word, handle: Word) {
        store_at(self.0, 0, server);
        store_at(self.0, 3, handle);
    }

    fn set_flags(self, flags: Word) {
        store_at(self.0, 6, flags);
    }
}

/// Process `p`'s descriptor `fd` if it names something; else E_BADF.
fn desc_of(p: Proc, fd: Word) -> Result<Desc, Word> {
    desc_of_any(p, fd).and_then(|d| if d.server() != 0 { Ok(d) } else { Err(E_BADF) })
}

/// The same for any descriptor in range, naming something or not.
fn desc_of_any(p: Proc, fd: Word) -> Result<Desc, Word> {
    if (0..NDESC).contains(&fd) {
        Ok(Desc::of(p, fd))
    } else {
        Err(E_BADF)
    }
}

/// Resume the caller with `r` as its result (ipc::RESUME).
fn done(p: Proc, r: Word) -> i32 {
    p.set(PCB_A0, r);
    ipc::RESUME
}

/// read(fd, buffer, n), write(fd, buffer, n) and iocall(fd, op, x, y):
/// call fd's server with the IO_ operation, the handle, and the two
/// arguments. The call goes on as ipc::call, from the rewritten saved
/// registers, so the caller sees what a call leaves: 1, it sleeps.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_read(p: *mut u8) -> i32 {
    let p = Proc(p);
    io(p, IO_READ, p.get(PCB_A2), p.get(PCB_A3))
}

#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_write(p: *mut u8) -> i32 {
    let p = Proc(p);
    io(p, IO_WRITE, p.get(PCB_A2), p.get(PCB_A3))
}

#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_iocall(p: *mut u8) -> i32 {
    let p = Proc(p);
    let op = p.get(PCB_A2);
    if op >= 0 || op < IO_FIRST {
        return done(p, E_INVAL);
    }
    io(p, op, p.get(PCB_A3), p.get(PCB_A4))
}

fn io(p: Proc, op: Word, x: Word, y: Word) -> i32 {
    let d = match desc_of(p, p.get(PCB_A1)) {
        Ok(d) => d,
        Err(e) => return done(p, e),
    };
    p.set(PCB_A5, y);
    p.set(PCB_A4, x);
    p.set(PCB_A3, d.handle());
    p.set(PCB_A2, op);
    p.set(PCB_A1, d.server() - 1);
    ipc::call(p)
}

/// close(fd)
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_close(p: *mut u8) {
    let p = Proc(p);
    let r = match desc_of(p, p.get(PCB_A1)) {
        Ok(d) => {
            let (server, handle) = (d.server(), d.handle());
            d.set(0, 0);
            d.set_flags(0);
            unref(p, server, handle);
            0
        }
        Err(e) => e,
    };
    p.set(PCB_A0, r);
}

/// dup2(fd, to): to becomes a copy of fd, which a child inherits whatever
/// fd's flags; what to held is closed.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_dup2(p: *mut u8) {
    let p = Proc(p);
    let r = dup2(p);
    p.set(PCB_A0, r);
}

fn dup2(p: Proc) -> Word {
    let from = match desc_of(p, p.get(PCB_A1)) {
        Ok(d) => d,
        Err(e) => return e,
    };
    let to_fd = p.get(PCB_A2);
    let to = match desc_of_any(p, to_fd) {
        Ok(d) => d,
        Err(e) => return e,
    };
    if to != from {
        let (server, handle) = (to.server(), to.handle()); // what it held
        to.set(from.server(), from.handle());
        to.set_flags(0);
        if server != 0 {
            unref(p, server, handle);
        }
    }
    to_fd
}

/// give(pid, handle): put the caller's handle in process pid's lowest free
/// descriptor. Pid must be waiting for the caller's reply, so a server
/// gives only to a process that asked it for something.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_give(p: *mut u8) {
    let p = Proc(p);
    let r = give(p);
    p.set(PCB_A0, r);
}

fn give(p: Proc) -> Word {
    let handle = p.get(PCB_A2);
    if !(0..NHANDLE).contains(&handle) {
        return E_INVAL;
    }
    let Some(client) = ipc::client_of(p, p.get(PCB_A1)) else {
        return E_NOPROC;
    };
    let Some(fd) = (0..NDESC).find(|&fd| Desc::of(client, fd).server() == 0) else {
        return E_MFILE;
    };
    let d = Desc::of(client, fd);
    d.set(p.pid() + 1, handle);
    d.set_flags(0);
    // A descriptor names it again: a notice not yet taken is stale.
    p.set_tryte(PCB_CLOSED + handle, 0);
    fd
}

/// fdflags(fd, flags): FD_NOINHERIT, or 0 for none.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_fdflags(p: *mut u8) {
    let p = Proc(p);
    let r = match desc_of(p, p.get(PCB_A1)) {
        Err(e) => e,
        Ok(d) => {
            let flags = p.get(PCB_A2);
            if flags == 0 || flags == FD_NOINHERIT {
                d.set_flags(flags);
                0
            } else {
                E_INVAL
            }
        }
    };
    p.set(PCB_A0, r);
}

/// A descriptor of process `p` naming `handle` of server `server` - 1
/// is gone. If none is left anywhere, tell the server, if it is still
/// there and is not `p` ending itself, with a NOTE_CLOSED notice.
fn unref(p: Proc, server: Word, handle: Word) {
    for q in Proc::table() {
        if Desc::all(q).any(|d| d.server() == server && d.handle() == handle) {
            return; // still named
        }
    }
    let Some(s) = Proc::alive(server - 1).filter(|&s| s != p) else {
        return;
    };
    s.set_tryte(PCB_CLOSED + handle, 1);
    s.rouse();
}

/// Process `pid`, record `p`, has ended (bury, through desc_ended). Its
/// descriptors close, and those naming it, which no call can reach now,
/// go: a later process with its number never sees calls for handles it
/// did not give.
#[unsafe(no_mangle)]
pub extern "C" fn rk_desc_ended(p: *mut u8, pid: i32) {
    let p = Proc(p);
    for d in Desc::all(p) {
        let (server, handle) = (d.server(), d.handle());
        if server != 0 {
            d.set(0, 0);
            unref(p, server, handle);
        }
    }
    let it = pid as Word + 1;
    for q in Proc::table() {
        for d in Desc::all(q) {
            if d.server() == it {
                d.set(0, 0);
            }
        }
    }
}

/// Give `child`, a record of all zeros, copies of the descriptors of
/// process `parent` if it has one: those without FD_NOINHERIT, each at
/// its own number (spawn, through desc_inherit).
#[unsafe(no_mangle)]
pub extern "C" fn rk_desc_inherit(child: *mut u8, parent: i32) {
    if parent < 0 {
        return;
    }
    let child = Proc(child);
    let parent = Proc::of(parent as Word);
    for fd in 0..NDESC {
        let from = Desc::of(parent, fd);
        if from.flags() == 0 {
            Desc::of(child, fd).set(from.server(), from.handle());
        }
    }
}
