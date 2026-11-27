//! Devices: who drives each, and passing its interrupts on. A device
//! belongs to the process that drives it (`drivers`, a record per
//! source, 0 for none): its registers are mapped into that process, and
//! the kernel only passes its interrupts on. The kernel keeps writing its
//! own messages to the console's output, its log, whoever drives it. The
//! driver arms a source when it expects an interrupt; the interrupt
//! masks it again, and receive hands the driver a NOTE_IRQ notice.
//! irq_armed counts the armed sources, so that pick waits for them
//! instead of calling a client stuck while its server waits on the
//! device. Every source is routed to hart 0 (the controller's reset
//! value), and interrupts are taken there under the kernel lock.

use crate::kdata::{self, read, write};
use crate::layout::*;
use crate::mem::page_at;
use crate::proc::Proc;
use crate::word::{Word, addr, load, load_at, store, store_at};

/// The leaf entry mapping each source's registers into its driver, by
/// source from 1: its register page, read and written by the process.
const DEV_PTE: [Word; NSRC as usize] = {
    const FLAGS: Word = PTE_LEAF + PTE_R + PTE_W + PTE_U + PTE_A + PTE_D;
    [
        P_CONSOLE * PAGE + FLAGS,
        P_DISK * PAGE + FLAGS,
        P_NET * PAGE + FLAGS,
    ]
};

/// Source `src`'s entry in `drivers`, for `src` from 1 to NSRC.
fn slot(src: Word) -> *mut u8 {
    kdata::drivers_base().wrapping_offset(3 * (src as i32 - 1) as isize)
}

/// Source `src`'s registers at the interrupt controller.
fn irq(src: Word) -> *mut u8 {
    addr(V_IRQ).wrapping_offset(9 * src as i32 as isize)
}

/// Mask source `src` if it is armed, and count it out.
fn disarm(src: Word) {
    let r = irq(src);
    if load_at(r, IRQ_ENABLE) != 0 {
        store_at(r, IRQ_ENABLE, 0);
        write::irq_armed(read::irq_armed() - 1);
    }
}

/// drive(source): make the caller source a1's driver, and map the
/// device's registers at V_DEVICE + PAGE * (a1 - 1). A program file may
/// not drive a device.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_drive(p: *mut u8) {
    let p = Proc(p);
    let src = p.get(PCB_A1);
    let r = if src <= 0 || src > NSRC {
        E_INVAL
    } else if p.get(PCB_FILE) != 0 {
        E_PERM
    } else {
        let s = slot(src);
        let me = p.addr_word();
        let now = load(s);
        if now == me {
            0 // its own already
        } else if now != 0 {
            E_BUSY
        } else {
            store(s, me);
            // Leaf entry NXPAGE + NWIN + source.
            let entry = page_at(p.get(PCB_LEAFPG))
                .wrapping_offset(3 * (NXPAGE + NWIN) as isize + 3 * src as i32 as isize);
            store(entry, DEV_PTE[src as usize - 1]);
            0
        }
    };
    p.set(PCB_A0, r);
}

/// arm(source): let source a1, which the caller drives, interrupt once.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_arm(p: *mut u8) {
    let p = Proc(p);
    let src = p.get(PCB_A1);
    let r = if src <= 0 || src > NSRC || load(slot(src)) != p.addr_word() {
        E_PERM
    } else {
        let r = irq(src);
        if load_at(r, IRQ_ENABLE) == 0 {
            store_at(r, IRQ_ENABLE, 1);
            write::irq_armed(read::irq_armed() + 1);
        }
        0
    };
    p.set(PCB_A0, r);
}

/// Tell the driver of every device source that wants attention (on hart
/// 0, from an external interrupt or idle): mask the source, flag it in
/// its driver's PCB_IRQS and wake the driver if it sleeps in receive. A
/// source nobody drives is only masked.
#[unsafe(no_mangle)]
pub extern "C" fn rk_device_irqs() {
    let ctl = addr(V_IRQ);
    loop {
        let src = load_at(ctl, IRQ_CLAIM);
        if src == 0 {
            break;
        }
        store_at(irq(src), IRQ_ENABLE, 0);
        write::irq_armed(read::irq_armed() - 1);
        let d = load(slot(src));
        if d != 0 {
            let d = Proc(addr(d));
            d.set_tryte(PCB_IRQS - 1 + src, 1);
            d.retry_if(ST_RECEIVE);
        }
        store_at(ctl, IRQ_COMPLETE, src);
    }
}

/// Process `p` has ended (bury): it drives nothing now, and what it
/// armed is masked. Its mapping went with its page tables.
#[unsafe(no_mangle)]
pub extern "C" fn rk_drv_ended(p: *mut u8) {
    let me = Proc(p).addr_word();
    for src in 1..NSRC + 1 {
        let s = slot(src);
        if load(s) == me {
            store(s, 0);
            disarm(src);
        }
    }
}
