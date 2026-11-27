//! The boot report: what the kernel found, on its log, before it starts
//! init, as BSD and Linux kernels say what they find as they boot. Each
//! line starts "trylobite: ", like every other line of the kernel's.

use crate::console::{putc, putn, puts};
use crate::harts::harts_present;
use crate::kdata::{self, read};
use crate::layout::*;
use crate::mem::pages;
use crate::word::{addr, load_small_at};

unsafe extern "C" {
    static msg_version: u8;
    static msg_about: u8;
    static msg_memory: u8;
    static msg_pages: u8;
    static msg_trytes: u8;
    static msg_free: u8;
    static msg_harts: u8;
    static msg_irq: u8;
    static msg_irq_at: u8;
    static msg_cons: u8;
    static msg_disk: u8;
    static msg_blocks: u8;
    static msg_nodisk: u8;
    static msg_net: u8;
    static msg_nolink: u8;
    static msg_atpage: u8;
    static msg_slots: u8;
    static msg_progs: u8;
    static msg_image: u8;
    static msg_init: u8;
}

/// One of kernel/data.s's messages.
macro_rules! msg {
    ($name:ident) => {
        puts(unsafe { &raw const $name })
    };
}

/// The version, then memory, harts, devices and the process table, one
/// line each. Hart 0 calls it at boot, after rk_page_init and before it
/// spawns init, so the free pages are those init can have.
#[unsafe(no_mangle)]
pub extern "C" fn rk_boot_report() {
    msg!(msg_version);
    puts(kdata::version());
    msg!(msg_about);

    // memory: N pages (T trytes), F free
    let ram = read::ram_pages();
    msg!(msg_memory);
    putn(ram as i32);
    msg!(msg_pages);
    putn(pages(ram));
    msg!(msg_trytes);
    putn(read::free_count() as i32);
    msg!(msg_free);

    msg!(msg_harts);
    putn(harts_present());
    putc(b'\n' as i32);

    // The devices, each on its page.
    msg!(msg_irq);
    putn(load_small_at(addr(V_IRQ), IRQ_SOURCES));
    msg!(msg_irq_at);
    at_page(P_IRQ);
    msg!(msg_cons);
    at_page(P_CONSOLE);
    msg!(msg_disk);
    let blocks = load_small_at(addr(V_DISK), DISK_BLOCKS);
    if blocks == 0 {
        msg!(msg_nodisk);
    } else {
        putn(blocks);
        msg!(msg_blocks);
    }
    at_page(P_DISK);
    msg!(msg_net);
    let net = addr(NET_KA);
    if load_small_at(net, NET_LINK) <= 0 {
        msg!(msg_nolink);
    } else {
        // Its address, as BSD's ifconfig shows it.
        octets(load_small_at(net, NET_MAC_HI));
        putc(b':' as i32);
        octets(load_small_at(net, NET_MAC_LO));
    }
    at_page(P_NET);

    // The process table, and the programs the image brings.
    msg!(msg_slots);
    putn(NPROC as i32);
    msg!(msg_progs);
    putn(read::nprog() as i32);
    msg!(msg_image);
    msg!(msg_init);
}

/// Print `v`, 24 bits, as three octets in hexadecimal with colons
/// between.
fn octets(v: i32) {
    let mut place = 65536;
    loop {
        let octet = v / place % 256;
        hex(octet / 16);
        hex(octet % 16);
        place /= 256;
        if place == 0 {
            break;
        }
        putc(b':' as i32);
    }
}

/// Print `d`, 0 to 15, as a hexadecimal digit.
fn hex(d: i32) {
    putc(if d < 10 {
        '0' as i32 + d
    } else {
        'a' as i32 + d - 10
    });
}

/// ", at page " `page` and the end of the line.
fn at_page(page: i64) {
    msg!(msg_atpage);
    putn(page as i32);
    putc(b'\n' as i32);
}
