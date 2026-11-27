//! Memory: what a process's addresses are in the kernel. kernel/mm.s and
//! kernel/ipc.s keep the assembly side until they are ported.

use crate::layout::*;
use crate::proc::Proc;
use crate::word::{Word, addr, load_at};

/// Where address `a` of process `p` is in the kernel, through the direct
/// map, and how many trytes its page has from there; None when the
/// process has nothing there: its own page, a page of its image above
/// that, a block window or a page of heap it has. The same as uva in
/// kernel/ipc.s.
pub fn uva(p: Proc, a: Word) -> Option<(*mut u8, Word)> {
    let from = a - (V_USER - 9841); // trytes from its own page's first
    if from < 0 {
        return None;
    }
    let k = from / PAGE; // 0 its page, k the k-th above it
    let off = from - k * PAGE;
    let page = if k == 0 {
        p.get(PCB_USERPG)
    } else if k <= NXPAGE + NWIN {
        // Image pages, then windows: PCB_WINS follows on from PCB_XPAGES.
        let page = p.get(PCB_XPAGES + 3 * (k - 1));
        if page == 0 {
            return None;
        }
        page
    } else {
        let h = k - HEAP_LEAF; // which page of its heap
        if h < 0 || h >= p.get(PCB_HEAP) {
            return None;
        }
        // Its leaf entry says which page.
        let leaf = addr(p.get(PCB_LEAFPG) * PAGE + DMAP + 3 * HEAP_LEAF);
        (load_at(leaf, 3 * h) - USER_FLAGS) / PAGE
    };
    Some((addr(page * PAGE + DMAP - 9841 + off), PAGE - off))
}
