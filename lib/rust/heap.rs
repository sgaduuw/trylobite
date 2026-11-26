//! A heap for a Rust program on trylobite, so that it may use `alloc`
//! (`Vec`, `String`, `Box`, `format!`). A program brings it in with
//!
//!     extern crate alloc;
//!     #[path = "../lib/rust/heap.rs"]
//!     mod heap;
//!
//! The memory comes from the kernel's `brk` (lib/rust/start.s), which
//! maps whole pages from HEAP_START and never takes them back. Free
//! blocks are a list in address order, each starting with its size and
//! the next block's address; an allocation takes the first that fits
//! and leaves what is left over on the list, and a block given back is
//! merged with the free blocks either side of it. Sizes and addresses
//! are multiples of UNIT, so a free block always has room for its two
//! fields.

use core::alloc::{GlobalAlloc, Layout};
use core::ptr::null_mut;

unsafe extern "C" {
    fn brk(end: usize) -> isize;
}

/// Bytes (trytes) per unit: room for a free block's size and link.
const UNIT: usize = 2 * core::mem::size_of::<usize>();

struct Free {
    size: usize,
    next: *mut Free,
}

struct Heap;

static mut LIST: *mut Free = null_mut();
/// The break, rounded up to a unit: where the heap ends; 0 before the
/// first allocation asks the kernel.
static mut TOP: usize = 0;

fn round(n: usize, to: usize) -> usize {
    (n + to - 1) / to * to
}

/// Put the block at `at`, `size` bytes, on the list, merged with its
/// neighbours.
unsafe fn give(at: usize, size: usize) {
    unsafe {
        let mut prev: *mut Free = null_mut();
        let mut cur = LIST;
        while !cur.is_null() && (cur as usize) < at {
            prev = cur;
            cur = (*cur).next;
        }
        let block = at as *mut Free;
        (*block).size = size;
        (*block).next = cur;
        if !cur.is_null() && at + size == cur as usize {
            (*block).size += (*cur).size;
            (*block).next = (*cur).next;
        }
        if prev.is_null() {
            LIST = block;
        } else if prev as usize + (*prev).size == at {
            (*prev).size += (*block).size;
            (*prev).next = (*block).next;
        } else {
            (*prev).next = block;
        }
    }
}

/// Take `size` bytes at a multiple of `align` from the list, or null.
unsafe fn take(size: usize, align: usize) -> *mut u8 {
    unsafe {
        let mut prev: *mut Free = null_mut();
        let mut cur = LIST;
        while !cur.is_null() {
            let at = cur as usize;
            let len = (*cur).size;
            let start = round(at, align);
            if start + size <= at + len {
                let next = (*cur).next;
                if prev.is_null() {
                    LIST = next;
                } else {
                    (*prev).next = next;
                }
                if start > at {
                    give(at, start - at);
                }
                if start + size < at + len {
                    give(start + size, at + len - start - size);
                }
                return start as *mut u8;
            }
            prev = cur;
            cur = (*cur).next;
        }
        null_mut()
    }
}

/// Ask the kernel for at least `more` bytes past the top, and put them
/// on the list: false if it has no more to give.
unsafe fn grow(more: usize) -> bool {
    unsafe {
        if TOP == 0 {
            TOP = round(brk(0) as usize, UNIT);
        }
        let end = brk(TOP + more);
        if end < 0 || (end as usize) < TOP + more {
            return false;
        }
        let end = end as usize / UNIT * UNIT;
        give(TOP, end - TOP);
        TOP = end;
        true
    }
}

unsafe impl GlobalAlloc for Heap {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let size = round(l.size().max(1), UNIT);
        let align = l.align().max(UNIT);
        unsafe {
            let p = take(size, align);
            if !p.is_null() || !grow(size + align) {
                return p;
            }
            take(size, align)
        }
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { give(p as usize, round(l.size().max(1), UNIT)) }
    }

    /// In place when it can be: shrinking gives the tail back, and
    /// growing takes what follows the block if that is free, or more
    /// from the kernel if the block ends the heap, so that a Vec growing
    /// at the top of the heap is never copied. Else as GlobalAlloc's own.
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let at = p as usize;
        let old = round(l.size().max(1), UNIT);
        let want = round(new.max(1), UNIT);
        unsafe {
            if want <= old {
                if want < old {
                    give(at + want, old - want);
                }
                return p;
            }
            if at + old == TOP && grow(want - old) {
                // The new pages are on the list now, next to the block.
            }
            if take_at(at + old, want - old) {
                return p;
            }
            let q = self.alloc(Layout::from_size_align_unchecked(new, l.align()));
            if !q.is_null() {
                core::ptr::copy_nonoverlapping(p, q, l.size());
                self.dealloc(p, l);
            }
            q
        }
    }
}

/// Take exactly the `size` bytes at `at` from the list, if a free block
/// holds them all: true if it did.
unsafe fn take_at(at: usize, size: usize) -> bool {
    unsafe {
        let mut prev: *mut Free = null_mut();
        let mut cur = LIST;
        while !cur.is_null() && (cur as usize) < at {
            prev = cur;
            cur = (*cur).next;
        }
        if cur as usize != at || (*cur).size < size {
            return false;
        }
        let (len, next) = ((*cur).size, (*cur).next);
        if prev.is_null() {
            LIST = next;
        } else {
            (*prev).next = next;
        }
        if len > size {
            give(at + size, len - size);
        }
        true
    }
}

#[global_allocator]
static HEAP: Heap = Heap;
