//! Locks for threads (`thread`): `Mutex` and `Condvar`, as std's, with
//! `Arc` and the atomics from `alloc` and `core`.
//!
//! A lock is a u32 that Rust's atomics change (detrytus docs/rust.md,
//! Atomics), and the kernel's futex (docs/kernel.md, Threads) lets a
//! thread that finds it taken sleep until the holder lets it go, rather
//! than spin through its time slice. A panic ends the whole program
//! (detrytus aborts), so a lock is never poisoned: `lock` always gives
//! `Ok`, and `PoisonError` is only there so that code written for std's
//! `lock().unwrap()` reads the same.

use core::cell::UnsafeCell;
use core::fmt;
use core::ops::{Deref, DerefMut};
use core::sync::atomic::{AtomicU32, Ordering};

use crate::sys;

pub use alloc::sync::{Arc, Weak};
pub use core::sync::atomic;

/// Sleep while the u32 at `word` is `value` (FUTEX_WAIT); a wake, or a
/// value that has changed already, returns.
pub(crate) fn futex_wait(word: &AtomicU32, value: u32) {
    sys::call(
        sys::SYS_FUTEX,
        &[word.as_ptr() as i32, sys::FUTEX_WAIT, value as i32],
    );
}

/// Wake at most `n` threads sleeping on `word` (FUTEX_WAKE).
pub(crate) fn futex_wake(word: &AtomicU32, n: i32) {
    sys::call(sys::SYS_FUTEX, &[word.as_ptr() as i32, sys::FUTEX_WAKE, n]);
}

/// Whether the program has started a thread: set by thread::spawn just
/// before its first, and never cleared. Until then nothing can contend
/// for the library's own locks.
static mut THREADED: bool = false;

/// Note that the program is about to have more than one thread.
pub(crate) fn threaded() {
    unsafe { core::ptr::addr_of_mut!(THREADED).write_volatile(true) }
}

/// The library's own lock (the heap, standard I/O), which no caller
/// holds across thread::spawn: taken only once a second thread may
/// exist, since a lock costs every allocation and print a few dozen
/// steps (detrytus atomics take a lock of their own).
pub(crate) struct LibLock {
    raw: RawLock,
}

impl LibLock {
    pub(crate) const fn new() -> LibLock {
        LibLock {
            raw: RawLock::new(),
        }
    }

    /// Whether to lock: once threads may run, for good. A thread that
    /// took it unlocked before the first spawn has let it go by then.
    fn needed() -> bool {
        unsafe { core::ptr::addr_of!(THREADED).read_volatile() }
    }

    pub(crate) fn lock(&self) {
        if Self::needed() {
            self.raw.lock();
        }
    }

    pub(crate) fn unlock(&self) {
        if Self::needed() {
            self.raw.unlock();
        }
    }
}

/// Free, taken, and taken with a thread asleep waiting for it.
const FREE: u32 = 0;
const TAKEN: u32 = 1;
const WAITED: u32 = 2;

/// A lock without data: what `Mutex` is made of, and what the library
/// guards its own state with (the heap, standard I/O).
pub(crate) struct RawLock {
    state: AtomicU32,
}

impl RawLock {
    pub(crate) const fn new() -> RawLock {
        RawLock {
            state: AtomicU32::new(FREE),
        }
    }

    pub(crate) fn lock(&self) {
        if self
            .state
            .compare_exchange(FREE, TAKEN, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
        {
            return;
        }
        // Say a thread waits, and sleep until the holder wakes one; the
        // lock is ours once the swap finds it free.
        while self.state.swap(WAITED, Ordering::Acquire) != FREE {
            futex_wait(&self.state, WAITED);
        }
    }

    pub(crate) fn try_lock(&self) -> bool {
        self.state
            .compare_exchange(FREE, TAKEN, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
    }

    pub(crate) fn unlock(&self) {
        if self.state.swap(FREE, Ordering::Release) == WAITED {
            futex_wake(&self.state, 1);
        }
    }
}

/// What std's lock calls give when a holder panicked. On trylobite a
/// panic ends the program, so it never comes back from `lock`.
pub struct PoisonError<T> {
    guard: T,
}

impl<T> PoisonError<T> {
    pub fn into_inner(self) -> T {
        self.guard
    }
}

impl<T> fmt::Debug for PoisonError<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PoisonError")
    }
}

pub type LockResult<G> = Result<G, PoisonError<G>>;

/// A value only one thread at a time may reach, as std's `Mutex`.
pub struct Mutex<T: ?Sized> {
    raw: RawLock,
    data: UnsafeCell<T>,
}

unsafe impl<T: ?Sized + Send> Send for Mutex<T> {}
unsafe impl<T: ?Sized + Send> Sync for Mutex<T> {}

impl<T> Mutex<T> {
    pub const fn new(value: T) -> Mutex<T> {
        Mutex {
            raw: RawLock::new(),
            data: UnsafeCell::new(value),
        }
    }

    pub fn into_inner(self) -> LockResult<T> {
        Ok(self.data.into_inner())
    }
}

impl<T: ?Sized> Mutex<T> {
    /// Wait until no other thread holds it, and hold it until the guard
    /// goes.
    pub fn lock(&self) -> LockResult<MutexGuard<'_, T>> {
        self.raw.lock();
        Ok(MutexGuard { lock: self })
    }

    /// Hold it if no other thread does: None if one does.
    pub fn try_lock(&self) -> Option<MutexGuard<'_, T>> {
        self.raw.try_lock().then_some(MutexGuard { lock: self })
    }

    pub fn get_mut(&mut self) -> LockResult<&mut T> {
        Ok(self.data.get_mut())
    }
}

impl<T: ?Sized + Default> Default for Mutex<T> {
    fn default() -> Mutex<T> {
        Mutex::new(T::default())
    }
}

/// A held `Mutex`: its value, until it goes.
pub struct MutexGuard<'a, T: ?Sized> {
    lock: &'a Mutex<T>,
}

impl<T: ?Sized> Deref for MutexGuard<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { &*self.lock.data.get() }
    }
}

impl<T: ?Sized> DerefMut for MutexGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.lock.data.get() }
    }
}

impl<T: ?Sized> Drop for MutexGuard<'_, T> {
    fn drop(&mut self) {
        self.lock.raw.unlock();
    }
}

/// Threads waiting for a change a `Mutex` guards, as std's `Condvar`.
/// A wait may end without a notify, as std's may, so wait in a loop
/// that tests what it waits for, or use `wait_while`.
pub struct Condvar {
    seq: AtomicU32,
}

impl Condvar {
    pub const fn new() -> Condvar {
        Condvar {
            seq: AtomicU32::new(0),
        }
    }

    /// Let the mutex go, sleep until a notify, and hold it again.
    pub fn wait<'a, T: ?Sized>(&self, guard: MutexGuard<'a, T>) -> LockResult<MutexGuard<'a, T>> {
        // A notify between letting go and sleeping changes seq, so the
        // futex does not sleep through it.
        let seq = self.seq.load(Ordering::Relaxed);
        let lock = guard.lock;
        drop(guard);
        futex_wait(&self.seq, seq);
        lock.lock()
    }

    /// Wait while `condition` holds for the guarded value.
    pub fn wait_while<'a, T: ?Sized, F: FnMut(&mut T) -> bool>(
        &self,
        mut guard: MutexGuard<'a, T>,
        mut condition: F,
    ) -> LockResult<MutexGuard<'a, T>> {
        while condition(&mut *guard) {
            guard = self.wait(guard)?;
        }
        Ok(guard)
    }

    pub fn notify_one(&self) {
        self.seq.fetch_add(1, Ordering::Release);
        futex_wake(&self.seq, 1);
    }

    pub fn notify_all(&self) {
        self.seq.fetch_add(1, Ordering::Release);
        futex_wake(&self.seq, i32::MAX);
    }
}

impl Default for Condvar {
    fn default() -> Condvar {
        Condvar::new()
    }
}
