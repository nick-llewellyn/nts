//! Sleep-aware (suspend-inclusive) monotonic clock readings.
//!
//! `boottime_micros` returns microseconds since an arbitrary per-boot
//! epoch. Unlike `std::time::Instant` (CLOCK_MONOTONIC /
//! mach_absolute_time), the sources below keep counting while the
//! device is suspended, so Dart-side projections and timeout budgets
//! anchored to this clock stay correct across deep sleep. Only
//! differences between readings are meaningful; the absolute value is
//! not comparable across processes or reboots.

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
    // SAFETY: `ts` is a valid, writable timespec. CLOCK_BOOTTIME is
    // supported on Linux >= 2.6.39 and every Android API level this
    // package targets; the call cannot fail there.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &raw mut ts) };
    debug_assert_eq!(rc, 0);
    (ts.tv_sec as i64) * 1_000_000 + (ts.tv_nsec as i64) / 1_000
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
    // it so the hot path is one clock read plus a mul/div.
    static TIMEBASE: OnceLock<mach2::mach_time::mach_timebase_info> = OnceLock::new();
    let tb = TIMEBASE.get_or_init(|| {
        let mut info = mach2::mach_time::mach_timebase_info { numer: 0, denom: 0 };
        // SAFETY: valid out-pointer; documented to always succeed.
        unsafe { mach2::mach_time::mach_timebase_info(&raw mut info) };
        info
    });
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
    use std::sync::OnceLock;
    // Best-effort fallback for unsupported targets: plain monotonic
    // elapsed time since a process-wide anchor. Does NOT count time
    // asleep; documented as such on the bridge function.
    static ANCHOR: OnceLock<std::time::Instant> = OnceLock::new();
    let anchor = ANCHOR.get_or_init(std::time::Instant::now);
    anchor.elapsed().as_micros() as i64
}

#[cfg(test)]
mod tests {
    use super::boottime_micros;

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
        std::thread::sleep(std::time::Duration::from_millis(50));
        let b = boottime_micros();
        let delta = b - a;
        // Loose bounds: schedulers oversleep, never undersleep (much).
        assert!(delta >= 45_000, "advanced only {delta}us over 50ms sleep");
        assert!(delta < 5_000_000, "implausible advance {delta}us");
    }

    #[test]
    fn value_fits_comfortably_in_i64() {
        let v = boottime_micros();
        assert!(v >= 0);
        // ~10k years of uptime in micros still leaves i64 headroom.
        assert!(v < i64::MAX / 4);
    }
}
