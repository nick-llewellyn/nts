//! Sleep-aware (suspend-inclusive) monotonic clock readings.
//!
//! `boottime_micros` returns microseconds since an arbitrary per-boot
//! epoch. Unlike `std::time::Instant` (CLOCK_MONOTONIC /
//! mach_absolute_time), the sources below keep counting while the
//! device is suspended, so Dart-side projections and timeout budgets
//! anchored to this clock stay correct across deep sleep. Only
//! differences between readings are meaningful; the absolute value is
//! not comparable across processes or reboots. [`BootInstant`] wraps a
//! reading in an `Instant`-shaped API for call sites that need a
//! sleep-aware deadline or time-to-live.

use std::ops::Add;
use std::time::Duration;

#[cfg(any(target_os = "android", target_os = "linux"))]
#[expect(
    unsafe_code,
    reason = "raw `clock_gettime(CLOCK_BOOTTIME)` syscall; std::time \
              deliberately exposes only the suspend-frozen \
              CLOCK_MONOTONIC, so libc is the only route to the \
              boot-time clock"
)]
pub(crate) fn boottime_micros() -> i64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable timespec.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &raw mut ts) };
    if rc != 0 {
        // CLOCK_BOOTTIME is supported on Linux >= 2.6.39 and every
        // Android API level this package targets, so this path is
        // theoretical. The only documented failure (EINVAL: clock id
        // unsupported) is deterministic per kernel — it either always
        // or never fires — so falling back cannot mix epochs between
        // calls.
        return instant_fallback_micros();
    }
    // Widen through i128: tv_sec/tv_nsec are i64 on LP64 targets but
    // i32 on 32-bit Android, so neither `as i64` (unnecessary_cast on
    // LP64) nor `i64::from` (useless_conversion on LP64) is portable.
    // i128::from is a real widening on every target, and the final
    // narrowing is safe: boot-relative micros fit i64 for ~292k years.
    (i128::from(ts.tv_sec) * 1_000_000 + i128::from(ts.tv_nsec) / 1_000) as i64
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
#[expect(
    unsafe_code,
    reason = "raw `mach_continuous_time` / `mach_timebase_info` kernel \
              calls via the mach2 crate; std::time deliberately uses \
              the suspend-frozen mach_absolute_time, so this is the \
              only route to the suspend-inclusive clock"
)]
pub(crate) fn boottime_micros() -> i64 {
    use std::sync::OnceLock;
    // mach_timebase_info is constant for the process lifetime; cache
    // the validated result so the hot path is one clock read plus a
    // mul/div. `None` records a failed or degenerate probe (non-zero
    // kern_return, zero numer/denom that would divide by zero below);
    // the decision is made once, so fallback readings never mix with
    // scaled readings.
    static TIMEBASE: OnceLock<Option<mach2::mach_time::mach_timebase_info>> = OnceLock::new();
    let tb = TIMEBASE.get_or_init(|| {
        let mut info = mach2::mach_time::mach_timebase_info { numer: 0, denom: 0 };
        // SAFETY: valid out-pointer to a mach_timebase_info.
        let kr = unsafe { mach2::mach_time::mach_timebase_info(&raw mut info) };
        (kr == mach2::kern_return::KERN_SUCCESS && info.numer != 0 && info.denom != 0)
            .then_some(info)
    });
    let Some(tb) = tb else {
        return instant_fallback_micros();
    };
    // SAFETY: no preconditions. mach_continuous_time (unlike
    // mach_absolute_time) includes time the system spent asleep —
    // Apple-documented suspend-inclusive monotonic source.
    let ticks = unsafe { mach2::mach_time::mach_continuous_time() };
    // Widen to u128 for the timebase scaling so numer/denom ratios
    // cannot overflow, then narrow: even at numer/denom = 125/3
    // (Apple Silicon worst case) the microsecond value fits i64 for
    // ~292k years of uptime.
    let nanos = u128::from(ticks) * u128::from(tb.numer) / u128::from(tb.denom);
    (nanos / 1_000) as i64
}

#[cfg(target_os = "windows")]
#[expect(
    unsafe_code,
    reason = "raw `QueryInterruptTimePrecise` call via windows-sys; \
              std::time deliberately uses the suspend-frozen QPC \
              source, so this is the only route to interrupt time"
)]
pub(crate) fn boottime_micros() -> i64 {
    // QueryInterruptTimePrecise reports interrupt time (includes
    // sleep/hibernation) in 100 ns units. Available since Windows 10 /
    // Server 2016, which is below the package's Windows floor.
    let mut t: u64 = 0;
    // SAFETY: valid out-pointer to a u64.
    unsafe {
        windows_sys::Win32::System::WindowsProgramming::QueryInterruptTimePrecise(&raw mut t);
    }
    (t / 10) as i64
}

#[cfg(not(any(
    target_os = "android",
    target_os = "linux",
    target_os = "ios",
    target_os = "macos",
    target_os = "windows"
)))]
pub(crate) fn boottime_micros() -> i64 {
    // Best-effort fallback for unsupported targets. Does NOT count
    // time asleep; documented as such on the bridge function.
    instant_fallback_micros()
}

/// A point on the sleep-aware clock read by [`boottime_micros`].
///
/// Drop-in replacement for `std::time::Instant` on the paths where a
/// budget or a time-to-live must keep elapsing while the device is
/// suspended. `Instant` is deliberately suspend-frozen on every
/// platform this package targets, so an `Instant`-anchored deadline
/// silently extends by the duration of a sleep — a `timeout_ms = 5000`
/// call that suspends mid-handshake resumes with most of its original
/// budget intact even though the caller's wall-clock limit has long
/// since passed.
///
/// Only differences between values are meaningful; the absolute value
/// is not comparable across processes or reboots. Both the
/// difference and the offset operations saturate rather than panic or
/// wrap, so callers can branch on `Duration::is_zero()` without
/// handling a negative case.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct BootInstant(i64);

impl BootInstant {
    /// Read the sleep-aware clock now.
    pub(crate) fn now() -> Self {
        Self(boottime_micros())
    }

    /// Construct from a raw microsecond reading on the same epoch as
    /// [`boottime_micros`]. Exists so tests can drive deadline and TTL
    /// logic across a synthetic suspend gap without sleeping.
    #[cfg(test)]
    pub(crate) fn from_micros(micros: i64) -> Self {
        Self(micros)
    }

    /// Time elapsed from `earlier` to `self`, saturating at
    /// [`Duration::ZERO`] when `earlier` is the later of the two.
    /// Mirrors `Instant::saturating_duration_since`.
    pub(crate) fn saturating_duration_since(self, earlier: Self) -> Duration {
        let delta = self.0.saturating_sub(earlier.0);
        u64::try_from(delta).map_or(Duration::ZERO, Duration::from_micros)
    }

    /// Time elapsed since `self`, saturating at [`Duration::ZERO`].
    /// Mirrors `Instant::elapsed`.
    pub(crate) fn elapsed(self) -> Duration {
        Self::now().saturating_duration_since(self)
    }
}

impl Add<Duration> for BootInstant {
    type Output = Self;

    /// Offset forward by `rhs`, saturating at [`i64::MAX`] rather than
    /// wrapping. A `Duration` large enough to saturate is ~292k years,
    /// so the clamp is unreachable for any real budget or TTL; it
    /// exists so a caller-supplied `timeout_ms` cannot produce a
    /// deadline in the past.
    fn add(self, rhs: Duration) -> Self {
        let micros = i64::try_from(rhs.as_micros()).unwrap_or(i64::MAX);
        Self(self.0.saturating_add(micros))
    }
}

/// Plain monotonic elapsed time since a process-wide anchor.
///
/// Suspend-frozen (`Instant` semantics), so it does NOT count time
/// asleep. Serves as the whole-body implementation on unsupported
/// targets and as the runtime escape hatch when a supported
/// platform's clock probe fails. Not compiled on Windows:
/// `QueryInterruptTimePrecise` returns no status and cannot fail.
#[cfg(not(target_os = "windows"))]
fn instant_fallback_micros() -> i64 {
    use std::sync::OnceLock;
    static ANCHOR: OnceLock<std::time::Instant> = OnceLock::new();
    let anchor = ANCHOR.get_or_init(std::time::Instant::now);
    anchor.elapsed().as_micros() as i64
}

#[cfg(test)]
mod tests {
    use super::{boottime_micros, BootInstant};
    use std::time::Duration;

    #[test]
    fn non_decreasing_across_consecutive_reads() {
        let mut prev = boottime_micros();
        for _ in 0..1_000 {
            let next = boottime_micros();
            assert!(next >= prev, "clock went backwards: {prev} -> {next}");
            prev = next;
        }
    }

    #[test]
    fn advances_roughly_with_real_time() {
        let a = boottime_micros();
        // Wait until >= 50ms of wall time has verifiably elapsed:
        // `thread::sleep` alone may return early on spurious wakeups /
        // signals, which would flake the lower bound below.
        let start = std::time::Instant::now();
        while start.elapsed() < std::time::Duration::from_millis(50) {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let b = boottime_micros();
        let delta = b - a;
        // Loose bounds: schedulers oversleep, never undersleep (much).
        assert!(delta >= 45_000, "advanced only {delta}us over 50ms wait");
        assert!(delta < 5_000_000, "implausible advance {delta}us");
    }

    #[test]
    fn value_fits_comfortably_in_i64() {
        let v = boottime_micros();
        assert!(v >= 0);
        // ~10k years of uptime in micros still leaves i64 headroom.
        assert!(v < i64::MAX / 4);
    }

    #[test]
    fn boot_instant_difference_matches_offset() {
        let base = BootInstant::from_micros(1_000_000);
        let later = base + Duration::from_millis(250);
        assert_eq!(
            later.saturating_duration_since(base),
            Duration::from_millis(250)
        );
    }

    #[test]
    fn boot_instant_difference_saturates_when_reversed() {
        let base = BootInstant::from_micros(1_000_000);
        let later = base + Duration::from_secs(5);
        assert_eq!(base.saturating_duration_since(later), Duration::ZERO);
    }

    #[test]
    fn boot_instant_add_saturates_instead_of_wrapping() {
        let base = BootInstant::from_micros(i64::MAX - 10);
        let bumped = base + Duration::from_secs(3600);
        assert_eq!(bumped, BootInstant::from_micros(i64::MAX));
        // The clamp must not produce a deadline in the past.
        assert_eq!(base.saturating_duration_since(bumped), Duration::ZERO);
    }

    #[test]
    fn boot_instant_now_advances_across_a_wait() {
        let a = BootInstant::now();
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_millis(50) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(a.elapsed() >= Duration::from_millis(45));
    }
}
