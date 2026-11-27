//! Memory: what a process's addresses are in the kernel. kernel/mm.s keeps
//! the assembly side until it is ported.

use crate::layout::*;
use crate::proc::Proc;
use crate::word::{Word, addr, load_at};

/// Where address `a` of process `p` is in the kernel, through the direct
/// map, and how many trytes its page has from there; None when the
/// process has nothing there: its own page, a page of its image above
/// that, a block window or a page of heap it has. The same as uva in
/// kernel/mm.s, which the assembly still calls.
pub fn uva(p: Proc, a: Word) -> Option<(*mut u8, Word)> {
    let at = user_at(p, a);
    (!at.is_null()).then(|| (at, page_left(a)))
}

/// uva's address alone, or null: an Option of two values comes back
/// through memory, and copies between processes ask this for every page
/// they touch.
pub fn user_at(p: Proc, a: Word) -> *mut u8 {
    let none = core::ptr::null_mut();
    let from = a - (V_USER - 9841); // trytes from its own page's first
    if from < 0 || from > i32::MAX as Word {
        return none;
    }
    // In 32 bits from here: a 64-bit division is a helper call.
    let from = from as i32;
    if from < PAGE as i32 {
        // Its own page, where most of what the kernel reads is.
        return page_at(p.get(PCB_USERPG)).wrapping_offset((from - 9841) as isize);
    }
    let k = from / PAGE as i32; // k: the k-th page above its own
    let off = from - k * PAGE as i32;
    let page = if k == 0 {
        p.get(PCB_USERPG)
    } else if k <= (NXPAGE + NWIN) as i32 {
        // Image pages, then windows: PCB_WINS follows on from PCB_XPAGES.
        let page = p.get(PCB_XPAGES + (3 * (k - 1)) as Word);
        if page == 0 {
            return none;
        }
        page
    } else {
        let h = k - HEAP_LEAF as i32; // which page of its heap
        if h < 0 || h as Word >= p.get(PCB_HEAP) {
            return none;
        }
        // Its leaf entry says which page.
        let leaf = page_at(p.get(PCB_LEAFPG)).wrapping_offset((3 * HEAP_LEAF) as isize);
        ((load_at(leaf, (3 * h) as Word) - USER_FLAGS) as i32 / PAGE as i32) as Word
    };
    page_at(page).wrapping_offset((off - 9841) as isize)
}

/// How many trytes the page of user address `a` has from `a` on, for an
/// address user_at found.
pub fn page_left(a: Word) -> Word {
    let from = (a - (V_USER - 9841)) as i32;
    let off = if from < PAGE as i32 {
        from
    } else {
        from % PAGE as i32
    };
    (PAGE as i32 - off) as Word
}

/// Physical page `page`'s first tryte, through the direct map. Every
/// kernel address is within ±2^31 (include/layout.s, MEM_MAX), so the
/// product is worked out in 32 bits.
fn page_at(page: Word) -> *mut u8 {
    addr(
        ((page as i32)
            .wrapping_mul(PAGE as i32)
            .wrapping_add(DMAP as i32)) as Word,
    )
}
