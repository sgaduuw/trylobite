//! Physical pages and address spaces: the page allocator, spawn and
//! spawnw, window, brk, phys, and giving a process's pages back when it
//! ends (release).
//!
//! Free pages are those never handed out, fresh_page up to ram_pages,
//! and a list of those given back, threaded through the pages
//! themselves: each free page's centre word holds the next free page's
//! number. Boot touches no page, so a machine of any size starts at once
//! and costs the emulator only the pages used. Page 0 is the boot page
//! and is never free, so 0 also means "none".

use crate::desc;
use crate::ipc;
use crate::kdata::{self, read, write};
use crate::layout::*;
use crate::mem::{page_at, page_left, pages, user_at};
use crate::proc::Proc;
use crate::procinfo;
use crate::trytes;
use crate::wait;
use crate::word::{Word, addr, load, load_at, store};

/// Physical page `page`'s address, as a page table entry holds it less
/// its flags. Every page is below MEM_MAX, so it is worked out in 32
/// bits.
#[inline(always)]
fn phys(page: Word) -> Word {
    pages(page) as Word
}

/// The page a page table entry with `flags` points at.
#[inline(always)]
fn page_of(entry: Word, flags: Word) -> Word {
    ((entry - flags) as i32 / PAGE as i32) as Word
}

/// Physical page `page`'s first tryte, through the direct map.
#[inline(always)]
fn first(page: Word) -> *mut u8 {
    page_at(page).wrapping_offset(-9841)
}

/// Read how much RAM the machine has, as much of it as the direct map
/// reaches, and make pages P_FREE on free (page_init, at boot).
#[unsafe(no_mangle)]
pub extern "C" fn rk_page_init() {
    let ram = load_at(addr(V_POWER), POWER_RAM).min(MEM_MAX);
    write::ram_pages(ram);
    let p_free = P_PROG0 + read::nprog();
    write::fresh_page(p_free);
    write::free_count((ram - p_free + 1).max(0)); // pages P_FREE to ram_pages
}

/// A free page, not cleared: one given back if there is one, else the
/// next never used. For a page about to be overwritten whole; the
/// caller checks free_count first.
pub fn take_page() -> Word {
    let head = read::free_head();
    let page = if head != 0 {
        write::free_head(load(page_at(head))); // unlink it
        head
    } else {
        let page = read::fresh_page();
        write::fresh_page(page + 1);
        page
    };
    write::free_count(read::free_count() - 1);
    page
}

/// take_page for the log's page at boot (log_init in kernel/console.s).
#[unsafe(no_mangle)]
pub extern "C" fn rk_take_page() -> i32 {
    take_page() as i32
}

/// A zeroed free page; the caller checks free_count first.
pub fn alloc_page() -> Word {
    let page = take_page();
    unsafe { core::ptr::write_bytes(first(page), 0, PAGE as usize) };
    page
}

/// Give page `page` back to the free list.
pub fn free_page(page: Word) {
    store(page_at(page), read::free_head()); // link it to the old head
    write::free_head(page);
    write::free_count(read::free_count() + 1);
}

/// Where the next word is, `n` words from `p`: tables are walked with a
/// pointer, as a word's index is 64 bits and costly to work with.
#[inline(always)]
fn words(p: *mut u8, n: i32) -> *mut u8 {
    p.wrapping_offset(3 * n as isize)
}

/// Start a program in a free slot, as a child of process `parent` (or
/// NO_PARENT): with `image` not 0, the program image the build loaded
/// in that page, copied whole; with `image` 0, the program file in the
/// block windows of `caller` from window PCB_A1 on (spawnw has checked
/// it), whose image takes `above` pages above the process's own. Its
/// process number, or E_NOSLOT or E_NOMEM.
fn spawn(caller: Proc, parent: Word, image: i32, above: i32) -> Word {
    // Find a free slot, starting after the last one handed out, so a
    // process number is not reused until the table wraps: a message
    // meant for a process that just exited should not reach a new one.
    let (base, end) = Proc::bounds();
    let mut s = addr(read::next_slot());
    let mut n = NPROC as i32;
    loop {
        if s >= end {
            s = base; // wrap around
        }
        if Proc(s).is(ST_EXITED) {
            break;
        }
        s = s.wrapping_offset(PCB_SIZE as isize);
        n -= 1;
        if n == 0 {
            return E_NOSLOT;
        }
    }
    let s = Proc(s);

    // Check memory before taking any.
    if (read::free_count() as i32) < PAGES_PER_PROCESS as i32 + above {
        return E_NOMEM;
    }

    unsafe { core::ptr::write_bytes(s.at(-1), 0, PCB_SIZE as usize) };
    s.set(PCB_PARENT, parent);
    s.set(PCB_FILE, (image == 0) as Word); // a program file may not drive a device
    // No hart's coprocessor bank is its yet: it starts from its zeroed
    // PCB_FPU, not what the slot's last tenant left.
    let me = s.addr_word();
    let mut owner = kdata::fpu_owner_base();
    for _ in 0..NHART as i32 {
        if load(owner) == me {
            store(owner, 0);
        }
        owner = words(owner, 1);
    }
    desc::rk_desc_inherit(s.0, parent as i32); // its parent's descriptors

    let root = alloc_page();
    s.set(PCB_ROOTPG, root);
    let mid = alloc_page();
    s.set(PCB_MIDPG, mid);
    let leaf = alloc_page();
    s.set(PCB_LEAFPG, leaf);
    let user = if image != 0 {
        let user = take_page(); // copied over whole: no need to clear it
        unsafe { core::ptr::copy_nonoverlapping(first(image as Word), first(user), PAGE as usize) };
        user
    } else {
        alloc_page() // zeroed: copy_mem fills in the image
    };
    s.set(PCB_USERPG, user);

    // Root entry 0: the mid table.
    store(page_at(root), phys(mid) + PTE_PTR);
    // Mid entries: -16 to -1 the direct map, 0 the kernel, +1 the process.
    let m = page_at(mid);
    let mut at = words(m, -(DMAP_SUPERS as i32));
    let mut e = DMAP_PTE;
    while at < m {
        store(at, e);
        e += SUPER;
        at = words(at, 1);
    }
    store(m, KLEAF_PTR);
    store(words(m, 1), phys(leaf) + PTE_PTR);
    // Leaf entry 0: the process's page, at V_USER; entries 1 to NXPAGE
    // its image's pages above it, if any.
    let mut entry = page_at(leaf);
    store(entry, phys(user) + USER_FLAGS);
    let mut x = s.at(PCB_XPAGES);
    for _ in 0..above {
        let page = alloc_page();
        store(x, page);
        entry = words(entry, 1);
        store(entry, phys(page) + USER_FLAGS);
        x = words(x, 1);
    }

    if image == 0 {
        // Copy its image in, from the caller's windows.
        let w = caller.get(PCB_A1) as i32; // the first window
        let head = page_at(load(words(caller.at(PCB_WINS), w)));
        let from = pages(w as Word) as Word + V_BLOCK + EXEC_IMAGE - 1;
        ipc::copy_mem(caller, from, s, V_USER - 1, load_at(head, EXEC_SIZE));
    }

    let pid = s.pid();
    s.set(PCB_PTBR, phys(root) + (3 * pid as i32 + 4) as Word); // its ASID pid + 1, mode +
    s.set(PCB_PC, V_USER);
    s.set(0, USER_SP);
    s.set(PCB_GP, USER_GP); // programs address their data from gp
    write::next_slot(s.at(PCB_SIZE) as isize as Word); // the next spawn looks after it
    // The slot's last tenant had this ASID: a new epoch makes each hart
    // drop its translations before running the new one (see resume).
    let epoch = words(kdata::epochs_base(), pid as i32);
    store(epoch, load(epoch) + 1);
    s.ready(); // a hart waiting for work can run it
    pid
}

/// Spawn init, program 0, at boot (kernel/entry.s): 1 if it started.
#[unsafe(no_mangle)]
pub extern "C" fn rk_spawn_init() -> i32 {
    write::next_slot(kdata::procs_base() as isize as Word); // spawn starts with slot 0
    let none = Proc(core::ptr::null_mut());
    (spawn(none, NO_PARENT, P_PROG0 as i32, 0) >= 0) as i32
}

/// spawn(program): start program image a1 as the caller's child. Its
/// process number, or E_NOSLOT, E_NOPROG or E_NOMEM.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_spawn(p: *mut u8) {
    let p = Proc(p);
    let n = p.get(PCB_A1);
    let r = if n < 0 || n >= read::nprog() {
        E_NOPROG
    } else {
        spawn(p, p.pid(), (P_PROG0 + n) as i32, 0)
    };
    p.set(PCB_A0, r);
}

/// spawnw(window, for, args, n): start the program file the caller has
/// read into its block windows, its first block in window a1 and the
/// rest in the windows after it. Window a1 must hold one: it starts with
/// EXEC_MAGIC, so a text file is refused, as is a window the caller does
/// not have, and the windows from it on must hold all EXEC_SIZE trytes
/// of its image. The new process is the caller's child, or with a2 not
/// FOR_SELF the child of process a2, whose call the caller holds: so the
/// file server starts a program for the process that asked. Its
/// arguments are the a4 trytes at a3 in the parent's memory, read there
/// whoever calls, so the file server passes on its client's without
/// copying them (ARG_MAX in include/layout.s).
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_spawnw(p: *mut u8) {
    let p = Proc(p);
    let r = spawnw(p);
    p.set(PCB_A0, r);
}

fn spawnw(p: Proc) -> Word {
    let w = p.get(PCB_A1);
    if w < 0 || w >= NWIN {
        return E_NOPROG;
    }
    let page = load(words(p.at(PCB_WINS), w as i32));
    if page == 0 {
        return E_NOPROG;
    }
    let head = page_at(page);
    let size = load_at(head, EXEC_SIZE);
    if load_at(head, BLOCK_W0) != EXEC_MAGIC || size < 0 || size > EXEC_MAX {
        return E_NOPROG;
    }
    // The whole file in the windows.
    let mut at = pages(w) as Word + V_BLOCK - 9841;
    let mut left = size + EXEC_HEAD;
    while left > 0 {
        if user_at(p, at).is_null() {
            return E_NOPROG;
        }
        let k = page_left(at);
        at += k;
        left -= k;
    }
    // The pages its image takes above the process's own.
    let above = if size <= EXEC_LOW {
        0
    } else {
        ((size - EXEC_LOW) as i32 + PAGE as i32 - 1) / PAGE as i32
    };

    let to = p.get(PCB_A2);
    let (parent, pid) = if to == FOR_SELF {
        (p, p.pid())
    } else {
        match ipc::client_of(p, to) {
            Some(c) => (c, to), // its child, if we hold its call
            None => return E_NOPROC,
        }
    };
    // The arguments must all be there: one page, as ARG_MAX is far
    // below one.
    let (args, n) = (p.get(PCB_A3), p.get(PCB_A4));
    if n < 0 || n > ARG_MAX {
        return E_INVAL;
    }
    let from = user_at(parent, args);
    if n > 0 && (from.is_null() || page_left(args) < n) {
        return E_FAULT;
    }
    let child = spawn(p, pid, 0, above);
    if child >= 0 {
        give_args(Proc::of(child), from, n);
    }
    child
}

/// Give process `c`, just made by spawnw, the `n` trytes of arguments
/// at kernel address `from`: copy them to V_ARGS in its page, a pointer
/// to each to V_ARGV, and start it with a0 = how many and a1 = V_ARGV.
/// The page below V_USER is still all 0, so each string and the list
/// end with a 0 whatever the block holds. It is named after argv[0].
fn give_args(c: Proc, from: *mut u8, n: Word) {
    let centre = page_at(c.get(PCB_USERPG));
    let mut argv = centre.wrapping_offset((V_ARGV - V_USER) as isize);
    let strings = centre.wrapping_offset((V_ARGS - V_USER) as isize);
    let mut count = 0;
    let mut starts = true; // the next tryte starts one
    for k in 0..n {
        if starts {
            store(argv, V_ARGS + k);
            argv = argv.wrapping_offset(3);
            count += 1;
        }
        let t = trytes::get(from.wrapping_offset(k as isize));
        trytes::put(strings.wrapping_offset(k as isize), t);
        starts = t == 0; // a 0 ends this one
    }
    c.set(PCB_A0, count);
    c.set(PCB_A1, V_ARGV);
    procinfo::name(c, strings, ARG_MAX); // argv[0], or none
}

/// window(k): give the caller block window a1, a zeroed page at V_BLOCK
/// + PAGE * a1, unless it has one there already.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_window(p: *mut u8) {
    let p = Proc(p);
    let k = p.get(PCB_A1);
    let r = if k < 0 || k >= NWIN {
        E_INVAL
    } else {
        let k = k as i32;
        let win = words(p.at(PCB_WINS), k);
        if load(win) != 0 {
            0
        } else if read::free_count() == 0 {
            E_NOMEM
        } else {
            let page = alloc_page();
            store(win, page);
            // Leaf entry NXPAGE + 1 + k: the window.
            let entry = words(page_at(p.get(PCB_LEAFPG)), NXPAGE as i32 + 1 + k);
            store(entry, phys(page) + USER_FLAGS);
            0
        }
    };
    p.set(PCB_A0, r);
}

/// brk(end): make the caller's heap reach end, a page at a time from
/// HEAP_START (leaf entries HEAP_LEAF on), and give back the break. It
/// never shrinks: an end inside it, or BRK_QUERY, only asks. All the
/// pages it needs, or none.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_brk(p: *mut u8) {
    let p = Proc(p);
    let r = brk(p, p.get(PCB_A1));
    p.set(PCB_A0, r);
}

fn brk(p: Proc, end: Word) -> Word {
    // Pages, at most HEAP_MAX, and trytes of heap, within an i32.
    let mut have = p.get(PCB_HEAP) as i32;
    if end != BRK_QUERY {
        let off = end - HEAP_START; // trytes from the heap's start
        if off < 0 || off > HEAP_MAX * PAGE {
            return E_INVAL;
        }
        let need = (off as i32 + PAGE as i32 - 1) / PAGE as i32;
        if need > have {
            if (read::free_count() as i32) < need - have {
                return E_NOMEM;
            }
            let mut entry = words(page_at(p.get(PCB_LEAFPG)), HEAP_LEAF as i32 + have);
            while have < need {
                let page = alloc_page(); // zeroed, as a new page should be
                store(entry, phys(page) + USER_FLAGS);
                entry = words(entry, 1);
                have += 1;
                p.set(PCB_HEAP, have as Word);
            }
        }
    }
    phys(have as Word) + HEAP_START // the break
}

/// phys(address): the physical address of the caller's address a1,
/// which only a driver needs: to give a device memory to move to or
/// from.
#[unsafe(no_mangle)]
pub extern "C" fn rk_sys_phys(p: *mut u8) {
    let p = Proc(p);
    let r = if !wait::drives_any(p) {
        E_PERM
    } else {
        let at = user_at(p, p.get(PCB_A1));
        if at.is_null() {
            E_FAULT
        } else {
            at as isize as Word - DMAP
        }
    };
    p.set(PCB_A0, r);
}

/// End process `p`: give back its pages and bury it (release in
/// kernel/syscall.s, which left its address space first: freeing a page
/// writes the free-list link into its centre word, which in a root table
/// is entry 0, and done while that table is live the next walk would
/// read garbage).
#[unsafe(no_mangle)]
pub extern "C" fn rk_release(p: *mut u8) {
    let p = Proc(p);
    // Its heap first, while its leaf table, which says where, is there.
    let mut entry = words(page_at(p.get(PCB_LEAFPG)), HEAP_LEAF as i32);
    for _ in 0..p.get(PCB_HEAP) as i32 {
        free_page(page_of(load(entry), USER_FLAGS));
        entry = words(entry, 1);
    }
    free_page(p.get(PCB_ROOTPG));
    free_page(p.get(PCB_MIDPG));
    free_page(p.get(PCB_LEAFPG));
    free_page(p.get(PCB_USERPG));
    // Its image's pages above its own, and its block windows.
    let mut x = p.at(PCB_XPAGES);
    for _ in 0..(NXPAGE + NWIN) as i32 {
        let page = load(x);
        if page != 0 {
            free_page(page);
        }
        x = words(x, 1);
    }
    wait::bury(p);
}
