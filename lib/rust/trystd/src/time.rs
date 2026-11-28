//! The time of day, as std's `time`: `SystemTime::now()` reads the
//! machine's real-time clock (SYS_CLOCK), and `duration_since` measures
//! from `UNIX_EPOCH` or any other moment.
//!
//! Where trylobite differs: there is no `Instant`, since the clock the
//! kernel times intervals with counts ticks, and how fast ticks pass in
//! real time depends on how the machine is run; and there is a calendar,
//! `Utc`, which std leaves to crates, so that tools such as bin/date need
//! not each carry one. There are no time zones: everything is UTC.

pub use core::time::Duration;

use core::fmt;

unsafe extern "C" {
    #[link_name = "clock"]
    fn raw_clock() -> u32;
}

/// A moment in wall-clock time: seconds and nanoseconds since the Unix
/// epoch, which may be negative for a moment before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SystemTime {
    secs: i64,
    nanos: u32, // 0 ..= 999,999,999, past secs
}

/// 1970-01-01 00:00:00 UTC.
pub const UNIX_EPOCH: SystemTime = SystemTime { secs: 0, nanos: 0 };

/// `duration_since` asked about a later moment: how much later it is.
#[derive(Clone, Debug)]
pub struct SystemTimeError(Duration);

impl SystemTimeError {
    pub fn duration(&self) -> Duration {
        self.0
    }
}

impl fmt::Display for SystemTimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("second time provided was later than self")
    }
}

const NANOS: u32 = 1_000_000_000;

impl SystemTime {
    pub const UNIX_EPOCH: SystemTime = UNIX_EPOCH;

    /// Now, to the microsecond, from the real-time clock.
    pub fn now() -> SystemTime {
        let low = unsafe { raw_clock() };
        let high = crate::sys::more(0);
        let micros = crate::sys::more(1);
        SystemTime { secs: ((high as i64) << 32) | low as i64, nanos: micros as u32 * 1000 }
    }

    /// Whole seconds since the Unix epoch, rounded down: what a Unix
    /// `time()` says. (Not in std, where this takes `duration_since`.)
    pub fn unix_seconds(&self) -> i64 {
        self.secs
    }

    /// The moment `secs` whole seconds after the Unix epoch.
    pub fn from_unix_seconds(secs: i64) -> SystemTime {
        SystemTime { secs, nanos: 0 }
    }

    /// How long after `earlier` this is, or, if `earlier` is the later
    /// one, an error holding how much later.
    pub fn duration_since(&self, earlier: SystemTime) -> Result<Duration, SystemTimeError> {
        if *self >= earlier {
            Ok(between(earlier, *self))
        } else {
            Err(SystemTimeError(between(*self, earlier)))
        }
    }

    /// How long ago this was.
    pub fn elapsed(&self) -> Result<Duration, SystemTimeError> {
        SystemTime::now().duration_since(*self)
    }

    pub fn checked_add(&self, d: Duration) -> Option<SystemTime> {
        let mut secs = self.secs.checked_add(i64::try_from(d.as_secs()).ok()?)?;
        let mut nanos = self.nanos + d.subsec_nanos();
        if nanos >= NANOS {
            nanos -= NANOS;
            secs = secs.checked_add(1)?;
        }
        Some(SystemTime { secs, nanos })
    }

    pub fn checked_sub(&self, d: Duration) -> Option<SystemTime> {
        let mut secs = self.secs.checked_sub(i64::try_from(d.as_secs()).ok()?)?;
        let nanos = if self.nanos >= d.subsec_nanos() {
            self.nanos - d.subsec_nanos()
        } else {
            secs = secs.checked_sub(1)?;
            self.nanos + NANOS - d.subsec_nanos()
        };
        Some(SystemTime { secs, nanos })
    }
}

/// From `a` to `b`, `b` not earlier.
fn between(a: SystemTime, b: SystemTime) -> Duration {
    let (mut secs, nanos) = if b.nanos >= a.nanos {
        (b.secs - a.secs, b.nanos - a.nanos)
    } else {
        (b.secs - a.secs - 1, b.nanos + NANOS - a.nanos)
    };
    if secs < 0 {
        secs = 0; // cannot happen when b >= a
    }
    Duration::new(secs as u64, nanos)
}

impl core::ops::Add<Duration> for SystemTime {
    type Output = SystemTime;
    fn add(self, d: Duration) -> SystemTime {
        self.checked_add(d).expect("overflow when adding duration to instant")
    }
}

impl core::ops::Sub<Duration> for SystemTime {
    type Output = SystemTime;
    fn sub(self, d: Duration) -> SystemTime {
        self.checked_sub(d).expect("overflow when subtracting duration from instant")
    }
}

/// A moment on the calendar, in UTC: the proleptic Gregorian calendar,
/// as Unix time counts it (every day 86,400 seconds, no leap seconds).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Utc {
    pub year: i64,
    /// 1 to 12.
    pub month: u32,
    /// 1 to 31.
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    /// 0 (Sunday) to 6 (Saturday).
    pub weekday: u32,
    /// The day of the year, 1 to 366.
    pub yday: u32,
}

/// Day names and month names, three letters each, as C's asctime.
pub const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
pub const MONTHS: [&str; 12] =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

impl Utc {
    /// The calendar moment `secs` seconds after the Unix epoch.
    pub fn from_unix(secs: i64) -> Utc {
        let days = secs.div_euclid(86_400);
        let rest = secs.rem_euclid(86_400) as u32;
        let (year, month, day) = civil_from_days(days);
        let yday = (days - days_from_civil(year, 1, 1)) as u32 + 1;
        Utc {
            year,
            month,
            day,
            hour: rest / 3600,
            minute: rest / 60 % 60,
            second: rest % 60,
            weekday: (days + 4).rem_euclid(7) as u32, // 1970-01-01 was a Thursday
            yday,
        }
    }

    /// The calendar moment of `t`, its fraction of a second dropped.
    pub fn from_system_time(t: SystemTime) -> Utc {
        Utc::from_unix(t.secs)
    }

    /// Back to seconds since the Unix epoch.
    pub fn to_unix(&self) -> i64 {
        days_from_civil(self.year, self.month, self.day) * 86_400
            + (self.hour * 3600 + self.minute * 60 + self.second) as i64
    }
}

/// Days since 1970-01-01 to a date, and back: Howard Hinnant's
/// algorithms, which count in 400-year eras of 146,097 days.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097); // 0 ..= 146,096
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // 0 ..= 399
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // 0 ..= 365, from March
    let mp = (5 * doy + 2) / 153; // 0 ..= 11, March first
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let m = month as i64;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}
