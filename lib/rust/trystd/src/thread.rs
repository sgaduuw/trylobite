//! Waiting, as std's `thread` has it. trylobite has no threads in a
//! process yet, so all there is is `sleep_ticks`.

unsafe extern "C" {
    #[link_name = "sleep_ticks"]
    fn raw_sleep_ticks(ticks: u32);
}

/// Wait at least `ticks` ticks of the time CSR (SYS_SLEEP). std's
/// `sleep` takes a Duration; the machine counts time in ticks, about a
/// million a second while it idles with a live console (detrytus
/// platform.md, Time), and as fast as it runs otherwise.
pub fn sleep_ticks(ticks: u32) {
    // At most 2^31 - 1, which start.s takes as it is.
    unsafe { raw_sleep_ticks(ticks.min(i32::MAX as u32)) }
}
