//! The kernel's calls, through user/fsd.s's stubs: `fs_sys` takes each
//! argument as a signed i32, and leaves a1 to a5 for `fs_more`. Words
//! that may not fit an i32 (a time, a stat buffer's words) go through
//! memory, with detrytus' word builtins, in buffers user/fsd.s lays out
//! word-aligned, which Rust cannot do itself.

unsafe extern "C" {
    fn fs_sys(n: i32, a1: i32, a2: i32, a3: i32, a4: i32, a5: i32) -> i32;
    fn fs_more(k: i32) -> i32;
    fn fs_exit(code: i32) -> !;
    /// SYS_CLOCK's seconds and microseconds, as two words at `out`.
    fn fs_clock(out: *mut u8);
    /// A node's sum over `n` words from `p`, N_SUM's counted as 0, as a
    /// word at `out` (lib/rust/tryfs/src/sum.rs).
    fn fs_sum(p: *const u8, n: i32, out: *mut u8);
    /// node::find in the leaf whose first word is at `node`, for the `n`
    /// words at `key`: the position and 1 if found exactly, at `out`.
    fn fs_find(node: *const u8, key: *const u8, n: i32, strict: i32, out: *mut u8);
    #[link_name = "detrytus.lw"]
    fn lw(p: *const u8) -> i64;
    #[link_name = "detrytus.sw"]
    fn sw(p: *mut u8, w: i64);
    #[link_name = "detrytus.tex"]
    fn tex(w: i64, pos: i32, len: i32) -> i64;
    /// Word-aligned buffers (user/fsd.s): a path coming in, PATH_MAX + 1
    /// trytes, and the words of what goes out or in.
    static fs_pathbuf: u8;
    static fs_words: u8;
    static fs_key: u8;
    static fs_found: u8;
}

/// System call `n`: its a0.
pub fn call(n: i64, a1: i64, a2: i64, a3: i64, a4: i64, a5: i64) -> i64 {
    unsafe { fs_sys(n as i32, a1 as i32, a2 as i32, a3 as i32, a4 as i32, a5 as i32) as i64 }
}

/// What the last call left in a1 (k = 0) to a5 (k = 4).
pub fn more(k: i32) -> i64 {
    unsafe { fs_more(k) as i64 }
}

pub fn exit(code: i64) -> ! {
    unsafe { fs_exit(code as i32) }
}

/// The time of day: seconds since 1970 and nanoseconds.
pub fn clock() -> (i64, i64) {
    let out = words();
    unsafe { fs_clock(out) };
    (word(out, 0), word(out, 1) * 1000)
}

/// The sum of the `n` words from `p`, word N_SUM counted as 0.
pub fn sum(p: *const u8, n: usize) -> i64 {
    let out = words();
    unsafe { fs_sum(p, n as i32, out) };
    word(out, 0)
}

/// node::find in the leaf whose first word is at `node` (user/fsd.s's
/// fs_find): the position of the first item whose key is `k` or more
/// (more when `strict`), and whether it is `k`.
pub fn find(node: *const u8, k: &[i64], strict: bool) -> (usize, bool) {
    let key = (&raw const fs_key).cast_mut();
    let out = (&raw const fs_found).cast_mut();
    for (i, &w) in k.iter().enumerate() {
        set_word(key, i, w);
    }
    unsafe { fs_find(node, key, k.len() as i32, strict as i32, out) };
    (word(out, 0) as usize, word(out, 1) != 0)
}

/// Word `i` from the word-aligned address `p`.
#[inline(always)]
pub fn word(p: *const u8, i: usize) -> i64 {
    unsafe { lw(p.wrapping_add(3 * i)) }
}

#[inline(always)]
pub fn set_word(p: *mut u8, i: usize, w: i64) {
    unsafe { sw(p.wrapping_add(3 * i), w) }
}

/// A word's three trytes, low first.
pub fn trytes(w: i64) -> [i64; 3] {
    unsafe { [tex(w, 0, 9), tex(w, 9, 9), tex(w, 18, 9)] }
}

/// The incoming path's buffer: its first tryte.
pub fn pathbuf() -> *mut u8 {
    (&raw const fs_pathbuf).cast_mut().wrapping_sub(1)
}

/// The words buffer: its first word's address (a word's centre).
pub fn words() -> *mut u8 {
    (&raw const fs_words).cast_mut()
}

/// An address as a call's argument.
pub fn addr(p: *const u8) -> i64 {
    p as usize as i64
}
