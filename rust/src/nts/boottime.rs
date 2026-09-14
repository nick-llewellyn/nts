//! Sleep-aware (suspend-inclusive) monotonic clock readings.
//!
//! Two read paths share one set of platform readers:
//!
//! - **Strict** — [`strict_read`] returns a [`StrictReading`] that
//!   names the [`ClockBackend`] it came from and the live
//!   [`generation`] it was taken under, or a typed [`ClockFault`] on
//!   *that* call. It never substitutes another source, never clamps,
//!   and uses checked arithmetic throughout. Every fault advances the
//!   process-wide generation so contexts holding the old value fail
//!   closed instead of continuing on a source that just misbehaved.
//! - **Legacy** — [`boottime_micros`] keeps the pre-strict contract for
//!   the bridge's `nts_boottime_micros` export: on the same faults it
//!   degrades to [`instant_fallback_micros`], a suspend-frozen
//!   process-local counter. That path is best-effort and nonportable
//!   by construction; no strict operation may reach it.
//!
//! Unlike `std::time::Instant` (CLOCK_MONOTONIC / mach_absolute_time),
//! the sources below keep counting while the device is suspended, so
//! Dart-side projections and timeout budgets anchored to them stay
//! correct across deep sleep. Only differences between readings taken
//! under one generation are meaningful; the absolute value is not
//! comparable across processes or reboots. [`BootInstant`] wraps a
//! reading in an `Instant`-shaped API for call sites that need a
//! sleep-aware deadline or time-to-live.
//!
//! ## Coordinate semantics (version [`SEMANTICS_VERSION`])
//!
//! - Origin: an arbitrary instant fixed for the current counter epoch
//!   (per boot on every supported platform). `0` is a valid reading.
//! - Unit: microseconds, floored from the native unit (see
//!   [`RawSample::to_micros`] for the exact per-backend rule).
//! - Range: `0..=i64::MAX`. A raw sample outside it is a
//!   [`ClockFault::ConversionOverflow`], never wrapped or clamped.
//! - Equal consecutive readings are valid; a strictly smaller reading
//!   from a sequential reader is a [`ClockFault::Regression`].

use std::ops::Add;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

/// Version of the coordinate semantics documented in the module doc.
/// Bump when origin, unit, range or comparison rules change.
pub(crate) const SEMANTICS_VERSION: u32 = 1;

/// Version of the raw-to-microsecond conversion rule implemented by
/// [`RawSample::to_micros`]. Bump when the rounding rule or the
/// per-backend scaling changes.
pub(crate) const CONVERSION_VERSION: u32 = 1;

/// Native source family a strict reading came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum ClockBackend {
    /// `clock_gettime(CLOCK_BOOTTIME)` (Android, Linux).
    LinuxBoottime,
    /// `mach_continuous_time` scaled by `mach_timebase_info` (iOS,
    /// macOS).
    AppleContinuous,
    /// `QueryInterruptTimePrecise` (Windows).
    WindowsInterruptTime,
}

/// The backend the current compile target reads, or `None` when the
/// target has no suspend-inclusive source this crate knows how to
/// read. Compile-time fact, not a probe result.
pub(crate) const fn platform_backend() -> Option<ClockBackend> {
    #[cfg(any(target_os = "android", target_os = "linux"))]
    {
        Some(ClockBackend::LinuxBoottime)
    }
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        Some(ClockBackend::AppleContinuous)
    }
    #[cfg(target_os = "windows")]
    {
        Some(ClockBackend::WindowsInterruptTime)
    }
    #[cfg(not(any(
        target_os = "android",
        target_os = "linux",
        target_os = "ios",
        target_os = "macos",
        target_os = "windows"
    )))]
    {
        None
    }
}

/// Why a strict read could not produce a reading.
///
/// Every variant is reported on the call that observed it; none is
/// deferred, and none is accompanied by a substitute value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ClockFault {
    /// The compile target has no supported suspend-inclusive source.
    Unsupported,
    /// `clock_gettime(CLOCK_BOOTTIME)` returned non-zero; `errno` is
    /// the value observed immediately afterwards.
    SyscallFailed { errno: i32 },
    /// `mach_timebase_info` returned a non-success `kern_return`, or a
    /// zero numerator / denominator that would make the scale
    /// undefined. Not cached: the next read probes again.
    TimebaseUnavailable {
        kern_return: i32,
        numer: u32,
        denom: u32,
    },
    /// A raw field was outside its documented domain (negative
    /// `tv_sec`, `tv_nsec` outside `0..1e9`).
    InvalidRaw,
    /// The checked scale or narrowing to `i64` microseconds failed.
    ConversionOverflow,
    /// A sequential reader observed a value strictly below its
    /// previous one.
    Regression { previous: i64, observed: i64 },
    /// A sequential reader's generation no longer matches the live
    /// one: some fault or reset happened since it was bound.
    GenerationChanged { expected: i64, observed: i64 },
}

/// A successful strict reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct StrictReading {
    /// Microseconds on the coordinate described in the module doc.
    pub micros: i64,
    /// Source the raw sample came from.
    pub backend: ClockBackend,
    /// Live generation at the time of the read.
    pub generation: i64,
}

/// Process-wide live generation. Starts at 1 so `0` can serve as an
/// "unbound" sentinel on the Dart side; advanced by [`observe_fault`]
/// and [`invalidate_generation`]. A generation is an invalidation
/// token for in-process contexts, not a boot or device identity.
static GENERATION: AtomicI64 = AtomicI64::new(1);

/// Current live generation.
pub(crate) fn generation() -> i64 {
    GENERATION.load(Ordering::Acquire)
}

/// Advance the live generation and return the new value. Called by
/// the bridge lifecycle (dispose / re-init) so contexts bound before
/// the reset cannot keep reading as if nothing happened.
pub(crate) fn invalidate_generation() -> i64 {
    GENERATION.fetch_add(1, Ordering::AcqRel) + 1
}

/// Record a fault: advance the generation and hand the fault back so
/// call sites can `?` it in one expression.
fn observe_fault(fault: ClockFault) -> ClockFault {
    invalidate_generation();
    fault
}

/// Raw platform sample before conversion. Carries the native unit so
/// the conversion rule is a pure, testable function on every host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RawSample {
    Linux { sec: i64, nsec: i64 },
    Apple { ticks: u64, numer: u32, denom: u32 },
    Windows { hundred_ns: u64 },
}

impl RawSample {
    /// Backend this sample belongs to.
    pub(crate) const fn backend(self) -> ClockBackend {
        match self {
            Self::Linux { .. } => ClockBackend::LinuxBoottime,
            Self::Apple { .. } => ClockBackend::AppleContinuous,
            Self::Windows { .. } => ClockBackend::WindowsInterruptTime,
        }
    }

    /// Convert to microseconds, flooring, with every step checked.
    ///
    /// - Linux: `sec * 1_000_000 + nsec / 1_000` with `sec >= 0` and
    ///   `0 <= nsec < 1_000_000_000` required.
    /// - Apple: `ticks * numer / denom / 1_000` in `u128`, `numer` and
    ///   `denom` non-zero required.
    /// - Windows: `hundred_ns / 10`.
    ///
    /// The result must fit `0..=i64::MAX`.
    pub(crate) fn to_micros(self) -> Result<i64, ClockFault> {
        let wide: i128 = match self {
            Self::Linux { sec, nsec } => {
                if sec < 0 || !(0..1_000_000_000).contains(&nsec) {
                    return Err(ClockFault::InvalidRaw);
                }
                i128::from(sec)
                    .checked_mul(1_000_000)
                    .and_then(|s| s.checked_add(i128::from(nsec) / 1_000))
                    .ok_or(ClockFault::ConversionOverflow)?
            }
            Self::Apple {
                ticks,
                numer,
                denom,
            } => {
                if numer == 0 || denom == 0 {
                    return Err(ClockFault::InvalidRaw);
                }
                let nanos = u128::from(ticks)
                    .checked_mul(u128::from(numer))
                    .ok_or(ClockFault::ConversionOverflow)?
                    / u128::from(denom);
                i128::try_from(nanos / 1_000).map_err(|_| ClockFault::ConversionOverflow)?
            }
            Self::Windows { hundred_ns } => i128::from(hundred_ns / 10),
        };
        i64::try_from(wide).map_err(|_| ClockFault::ConversionOverflow)
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
#[expect(
    unsafe_code,
    reason = "raw `clock_gettime(CLOCK_BOOTTIME)` syscall; std::time \
              deliberately exposes only the suspend-frozen \
              CLOCK_MONOTONIC, so libc is the only route to the \
              boot-time clock"
)]
fn platform_raw_read() -> Result<RawSample, ClockFault> {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable timespec.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &raw mut ts) };
    if rc != 0 {
        // CLOCK_BOOTTIME is supported on Linux >= 2.6.39 and every
        // Android API level this package targets, so this path is
        // theoretical; the strict contract still reports it on the
        // call that saw it rather than reasoning about determinism.
        let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
        return Err(ClockFault::SyscallFailed { errno });
    }
    // Widen through i64: tv_sec/tv_nsec are i64 on LP64 targets but
    // i32 on 32-bit Android, so neither `as i64` (unnecessary_cast on
    // LP64) nor `i64::from` (useless_conversion on LP64) is portable.
    // `i128::from` is a real widening on every target; the narrowing
    // back to i64 is checked.
    let sec = i64::try_from(i128::from(ts.tv_sec)).map_err(|_| ClockFault::InvalidRaw)?;
    let nsec = i64::try_from(i128::from(ts.tv_nsec)).map_err(|_| ClockFault::InvalidRaw)?;
    Ok(RawSample::Linux { sec, nsec })
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
#[expect(
    unsafe_code,
    reason = "raw `mach_continuous_time` / `mach_timebase_info` kernel \
              calls via the mach2 crate; std::time deliberately uses \
              the suspend-frozen mach_absolute_time, so this is the \
              only route to the suspend-inclusive clock"
)]
fn platform_raw_read() -> Result<RawSample, ClockFault> {
    use std::sync::OnceLock;
    // mach_timebase_info is constant for the process lifetime, so a
    // *successful* probe is cached and the hot path is one clock read
    // plus a mul/div. A failed or degenerate probe is deliberately not
    // cached: it is reported on this call, and the next call probes
    // again, so a fault never becomes a permanent silent state.
    static TIMEBASE: OnceLock<mach2::mach_time::mach_timebase_info> = OnceLock::new();
    let tb = match TIMEBASE.get() {
        Some(tb) => *tb,
        None => {
            let mut info = mach2::mach_time::mach_timebase_info { numer: 0, denom: 0 };
            // SAFETY: valid out-pointer to a mach_timebase_info.
            let kr = unsafe { mach2::mach_time::mach_timebase_info(&raw mut info) };
            if kr != mach2::kern_return::KERN_SUCCESS || info.numer == 0 || info.denom == 0 {
                return Err(ClockFault::TimebaseUnavailable {
                    kern_return: kr,
                    numer: info.numer,
                    denom: info.denom,
                });
            }
            *TIMEBASE.get_or_init(|| info)
        }
    };
    // SAFETY: no preconditions. mach_continuous_time (unlike
    // mach_absolute_time) includes time the system spent asleep —
    // Apple-documented suspend-inclusive monotonic source. It returns
    // no status; a failure is not observable here, which is why the
    // timebase probe above is the only Apple fault arm.
    let ticks = unsafe { mach2::mach_time::mach_continuous_time() };
    Ok(RawSample::Apple {
        ticks,
        numer: tb.numer,
        denom: tb.denom,
    })
}

#[cfg(target_os = "windows")]
#[expect(
    unsafe_code,
    reason = "raw `QueryInterruptTimePrecise` call via windows-sys; \
              std::time deliberately uses the suspend-frozen QPC \
              source, so this is the only route to interrupt time"
)]
fn platform_raw_read() -> Result<RawSample, ClockFault> {
    // QueryInterruptTimePrecise reports interrupt time (includes
    // sleep/hibernation) in 100 ns units. Available since Windows 10 /
    // Server 2016, which is below the package's Windows floor. It
    // returns no status, so conversion is the only Windows fault arm.
    let mut t: u64 = 0;
    // SAFETY: valid out-pointer to a u64.
    unsafe {
        windows_sys::Win32::System::WindowsProgramming::QueryInterruptTimePrecise(&raw mut t);
    }
    Ok(RawSample::Windows { hundred_ns: t })
}

#[cfg(not(any(
    target_os = "android",
    target_os = "linux",
    target_os = "ios",
    target_os = "macos",
    target_os = "windows"
)))]
fn platform_raw_read() -> Result<RawSample, ClockFault> {
    Err(ClockFault::Unsupported)
}

/// Boxed stand-in for [`platform_raw_read`], installed per thread by
/// [`with_raw_override`].
#[cfg(test)]
type RawReader = Box<dyn FnMut() -> Result<RawSample, ClockFault>>;

#[cfg(test)]
thread_local! {
    /// Test seam: when set, replaces [`platform_raw_read`] on this
    /// thread only, so injected faults cannot leak into tests running
    /// concurrently on other threads.
    static RAW_OVERRIDE: std::cell::RefCell<Option<RawReader>> =
        const { std::cell::RefCell::new(None) };
}

/// Run `body` with `reader` standing in for the platform reader on the
/// current thread, restoring the previous seam afterwards (also on
/// panic).
#[cfg(test)]
pub(crate) fn with_raw_override<R>(
    reader: impl FnMut() -> Result<RawSample, ClockFault> + 'static,
    body: impl FnOnce() -> R,
) -> R {
    struct Restore(Option<RawReader>);
    impl Drop for Restore {
        fn drop(&mut self) {
            let prev = self.0.take();
            RAW_OVERRIDE.with(|slot| *slot.borrow_mut() = prev);
        }
    }
    let prev = RAW_OVERRIDE.with(|slot| slot.borrow_mut().replace(Box::new(reader)));
    let _restore = Restore(prev);
    body()
}

fn raw_read() -> Result<RawSample, ClockFault> {
    #[cfg(test)]
    {
        let injected = RAW_OVERRIDE.with(|slot| slot.borrow_mut().as_mut().map(|f| f()));
        if let Some(r) = injected {
            return r;
        }
    }
    platform_raw_read()
}

/// Read the native source and convert it, recording any fault against
/// the live generation. Shared by the strict and legacy paths.
fn read_checked() -> Result<(i64, ClockBackend), ClockFault> {
    let raw = raw_read().map_err(observe_fault)?;
    let micros = raw.to_micros().map_err(observe_fault)?;
    Ok((micros, raw.backend()))
}

/// Strict read: a provenance-attributed reading or a typed fault on
/// this call. No fallback, no clamp, no deferred notification.
///
/// The generation is loaded *before* the raw read so a reading can
/// never carry a generation newer than the source state it was taken
/// under.
pub(crate) fn strict_read() -> Result<StrictReading, ClockFault> {
    let generation = generation();
    let (micros, backend) = read_checked()?;
    Ok(StrictReading {
        micros,
        backend,
        generation,
    })
}

/// A reader that checks monotonicity across *its own* sequence of
/// reads and stays bound to the generation it was created under.
///
/// Concurrent readers on different threads may legitimately publish
/// readings out of order (thread A reads 100, thread B reads 101, B
/// stores first), so a process-wide `fetch_max` would report false
/// regressions. Each `SequentialReader` therefore compares only
/// readings it took itself, in program order; that is the only
/// relation under which "smaller than the previous" means the source
/// went backwards.
#[derive(Debug)]
pub(crate) struct SequentialReader {
    generation: i64,
    last: Option<i64>,
}

impl SequentialReader {
    /// Bind a reader to the current live generation without reading.
    pub(crate) fn bind() -> Self {
        Self {
            generation: generation(),
            last: None,
        }
    }

    /// Generation this reader is bound to.
    pub(crate) fn generation(&self) -> i64 {
        self.generation
    }

    /// Take the next reading. Fails with [`ClockFault::GenerationChanged`]
    /// when the live generation moved since [`bind`](Self::bind), and
    /// with [`ClockFault::Regression`] when the value is strictly
    /// below this reader's previous one (equal is fine). Either fault
    /// leaves the reader permanently failing: `last` is not updated,
    /// and a regression advances the generation so the mismatch is
    /// reported on every later call.
    pub(crate) fn read(&mut self) -> Result<StrictReading, ClockFault> {
        let reading = strict_read()?;
        if reading.generation != self.generation {
            return Err(ClockFault::GenerationChanged {
                expected: self.generation,
                observed: reading.generation,
            });
        }
        if let Some(previous) = self.last {
            if reading.micros < previous {
                return Err(observe_fault(ClockFault::Regression {
                    previous,
                    observed: reading.micros,
                }));
            }
        }
        self.last = Some(reading.micros);
        Ok(reading)
    }
}

/// Legacy best-effort reading for the bridge's `nts_boottime_micros`
/// export and the pre-epoch T1 origin token.
///
/// Same platform readers and conversion as [`strict_read`], but on any
/// fault it degrades to [`instant_fallback_micros`] instead of
/// reporting. That makes the value **nonportable and non-strict**: a
/// caller cannot tell a native reading from the suspend-frozen
/// process-local counter, and the two are on different epochs. Kept
/// only for source compatibility; no strict operation may call it.
pub(crate) fn boottime_micros() -> i64 {
    match read_checked() {
        Ok((micros, _)) => micros,
        Err(_) => instant_fallback_micros(),
    }
}

/// A point on the sleep-aware clock.
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
/// Only differences between values taken under one generation are
/// meaningful; the absolute value is not comparable across processes
/// or reboots. Two families of operations exist:
///
/// - **Strict**: [`try_now`](Self::try_now) and
///   [`checked_duration_since`](Self::checked_duration_since) report a
///   [`ClockFault`] instead of substituting a value. A reversed pair
///   is a [`ClockFault::Regression`], not zero elapsed time.
/// - **Legacy**: [`now`](Self::now), [`elapsed`](Self::elapsed) and
///   [`saturating_duration_since`](Self::saturating_duration_since)
///   keep the pre-strict shape for call sites not yet migrated. They
///   read through [`boottime_micros`] and so can silently land on the
///   process-local fallback epoch; no strict operation may use them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct BootInstant(i64);

impl BootInstant {
    /// Strict read of the sleep-aware clock now.
    pub(crate) fn try_now() -> Result<Self, ClockFault> {
        strict_read().map(Self::from)
    }

    /// Legacy read of the sleep-aware clock now. See the type doc.
    pub(crate) fn now() -> Self {
        Self(boottime_micros())
    }

    /// Construct from a raw microsecond reading on the same epoch as
    /// [`strict_read`]. Exists so tests can drive deadline and TTL
    /// logic across a synthetic suspend gap without sleeping.
    #[cfg(test)]
    pub(crate) fn from_micros(micros: i64) -> Self {
        Self(micros)
    }

    /// Raw microsecond coordinate.
    pub(crate) fn micros(self) -> i64 {
        self.0
    }

    /// Time elapsed from `earlier` to `self`. Equal instants yield
    /// [`Duration::ZERO`]; `self < earlier` is reported as
    /// [`ClockFault::Regression`] rather than collapsed to zero.
    pub(crate) fn checked_duration_since(self, earlier: Self) -> Result<Duration, ClockFault> {
        if self.0 < earlier.0 {
            return Err(ClockFault::Regression {
                previous: earlier.0,
                observed: self.0,
            });
        }
        // Non-negative by the guard above; `i64::MAX` fits `u64`.
        Ok(Duration::from_micros(self.0.abs_diff(earlier.0)))
    }

    /// Time elapsed from `earlier` to `self`, saturating at
    /// [`Duration::ZERO`] when `earlier` is the later of the two.
    /// Mirrors `Instant::saturating_duration_since`. Legacy: hides a
    /// backwards pair; strict paths use
    /// [`checked_duration_since`](Self::checked_duration_since).
    pub(crate) fn saturating_duration_since(self, earlier: Self) -> Duration {
        let delta = self.0.saturating_sub(earlier.0);
        u64::try_from(delta).map_or(Duration::ZERO, Duration::from_micros)
    }

    /// Time elapsed since `self`, saturating at [`Duration::ZERO`].
    /// Mirrors `Instant::elapsed`. Legacy; see the type doc.
    pub(crate) fn elapsed(self) -> Duration {
        Self::now().saturating_duration_since(self)
    }
}

impl From<StrictReading> for BootInstant {
    fn from(reading: StrictReading) -> Self {
        Self(reading.micros)
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
/// asleep. Reached only from the legacy [`boottime_micros`] path: on
/// unsupported targets, and when a supported platform's read or
/// conversion faults. Never reached from [`strict_read`].
fn instant_fallback_micros() -> i64 {
    use std::sync::OnceLock;
    static ANCHOR: OnceLock<std::time::Instant> = OnceLock::new();
    let anchor = ANCHOR.get_or_init(std::time::Instant::now);
    i64::try_from(anchor.elapsed().as_micros()).unwrap_or(i64::MAX)
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

    // ---- strict path -------------------------------------------------

    use super::{
        generation, invalidate_generation, platform_backend, strict_read, with_raw_override,
        ClockBackend, ClockFault, RawSample, SequentialReader, StrictReading,
    };
    use std::cell::Cell;
    use std::rc::Rc;

    /// Injects `samples` in order, then keeps returning the last one.
    fn scripted(
        samples: Vec<Result<RawSample, ClockFault>>,
    ) -> impl FnMut() -> Result<RawSample, ClockFault> + 'static {
        let idx = Cell::new(0usize);
        move || {
            let i = idx.get();
            let r = samples[i.min(samples.len() - 1)];
            idx.set(i + 1);
            r
        }
    }

    fn linux(sec: i64, nsec: i64) -> Result<RawSample, ClockFault> {
        Ok(RawSample::Linux { sec, nsec })
    }

    #[test]
    fn strict_read_on_this_host_matches_platform_backend() {
        match (strict_read(), platform_backend()) {
            (Ok(r), Some(backend)) => {
                assert_eq!(r.backend, backend);
                assert!(r.micros >= 0);
                assert!(r.generation >= 1);
            }
            (Err(ClockFault::Unsupported), None) => {}
            (r, b) => panic!("host read {r:?} disagrees with compile-time backend {b:?}"),
        }
    }

    #[test]
    fn strict_read_never_falls_back_on_startup_fault() {
        let fallback_probe = Rc::new(Cell::new(0u32));
        let seen = Rc::clone(&fallback_probe);
        with_raw_override(
            move || {
                seen.set(seen.get() + 1);
                Err(ClockFault::SyscallFailed { errno: 22 })
            },
            || {
                let before = generation();
                let r = strict_read();
                assert_eq!(r, Err(ClockFault::SyscallFailed { errno: 22 }));
                assert!(generation() > before, "fault must advance the generation");
                // Legacy path degrades; strict path reported. Same seam,
                // two contracts.
                let legacy = super::boottime_micros();
                assert!(legacy >= 0);
            },
        );
        assert_eq!(fallback_probe.get(), 2, "one strict + one legacy raw read");
    }

    #[test]
    fn sequential_reader_fails_on_success_then_fault_and_stays_failed() {
        with_raw_override(
            scripted(vec![
                linux(10, 0),
                linux(10, 500),
                Err(ClockFault::TimebaseUnavailable {
                    kern_return: 5,
                    numer: 0,
                    denom: 0,
                }),
                linux(11, 0),
            ]),
            || {
                let mut reader = SequentialReader::bind();
                assert_eq!(reader.read().map(|r| r.micros), Ok(10_000_000));
                assert_eq!(reader.read().map(|r| r.micros), Ok(10_000_000));
                let bound = reader.generation();
                assert!(matches!(
                    reader.read(),
                    Err(ClockFault::TimebaseUnavailable { kern_return: 5, .. })
                ));
                // The source recovered, but this reader was bound to the
                // generation the fault retired: it must not resume.
                assert!(matches!(
                    reader.read(),
                    Err(ClockFault::GenerationChanged { expected, observed })
                        if expected == bound && observed > bound
                ));
            },
        );
    }

    #[test]
    fn re_resolution_after_fault_yields_a_fresh_valid_reader() {
        with_raw_override(
            scripted(vec![
                Err(ClockFault::SyscallFailed { errno: 1 }),
                linux(3, 0),
            ]),
            || {
                let mut stale = SequentialReader::bind();
                assert!(matches!(
                    stale.read(),
                    Err(ClockFault::SyscallFailed { errno: 1 })
                ));
                let mut fresh = SequentialReader::bind();
                let r = fresh.read().expect("fresh reader after recovery");
                assert_eq!(r.micros, 3_000_000);
                assert_eq!(r.generation, fresh.generation());
                assert!(fresh.generation() > stale.generation());
                // Old reader remains unusable even though the source is fine.
                assert!(matches!(
                    stale.read(),
                    Err(ClockFault::GenerationChanged { .. })
                ));
            },
        );
    }

    #[test]
    fn zero_and_equal_readings_are_valid() {
        with_raw_override(
            scripted(vec![linux(0, 0), linux(0, 0), linux(0, 999)]),
            || {
                let mut reader = SequentialReader::bind();
                assert_eq!(reader.read().map(|r| r.micros), Ok(0));
                assert_eq!(reader.read().map(|r| r.micros), Ok(0));
                // 999 ns floors to 0 us: still equal, still valid.
                assert_eq!(reader.read().map(|r| r.micros), Ok(0));
            },
        );
    }

    #[test]
    fn regression_is_reported_not_saturated_and_invalidates() {
        with_raw_override(scripted(vec![linux(5, 0), linux(4, 999_999_999)]), || {
            let mut reader = SequentialReader::bind();
            let before = reader.generation();
            assert_eq!(reader.read().map(|r| r.micros), Ok(5_000_000));
            assert_eq!(
                reader.read(),
                Err(ClockFault::Regression {
                    previous: 5_000_000,
                    observed: 4_999_999,
                })
            );
            assert!(generation() > before);
            assert!(matches!(
                reader.read(),
                Err(ClockFault::GenerationChanged { .. })
            ));
        });
    }

    #[test]
    fn checked_duration_since_reports_reversed_pair() {
        let a = BootInstant::from_micros(1_000);
        let b = BootInstant::from_micros(1_000);
        let c = BootInstant::from_micros(999);
        assert_eq!(b.checked_duration_since(a), Ok(Duration::ZERO));
        assert_eq!(
            c.checked_duration_since(a),
            Err(ClockFault::Regression {
                previous: 1_000,
                observed: 999,
            })
        );
        assert_eq!(
            BootInstant::from_micros(i64::MAX).checked_duration_since(BootInstant::from_micros(0)),
            Ok(Duration::from_micros(u64::try_from(i64::MAX).unwrap()))
        );
    }

    #[test]
    fn concurrent_readers_do_not_see_false_regressions() {
        // Each thread owns its reader; ordering between threads is
        // irrelevant to the per-reader check, so no thread may fail.
        let handles: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(|| {
                    let mut reader = SequentialReader::bind();
                    for _ in 0..2_000 {
                        match reader.read() {
                            Ok(_) | Err(ClockFault::Unsupported) => {}
                            // Another test on another thread may advance
                            // the generation via an injected fault; that
                            // is the documented shared-token behaviour,
                            // not a regression.
                            Err(ClockFault::GenerationChanged { .. }) => break,
                            Err(other) => panic!("unexpected fault: {other:?}"),
                        }
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
    }

    #[test]
    fn invalidate_generation_is_strictly_increasing() {
        let a = invalidate_generation();
        let b = invalidate_generation();
        assert!(b > a);
        assert!(generation() >= b);
    }

    #[test]
    fn reading_generation_never_exceeds_live_generation() {
        with_raw_override(scripted(vec![linux(1, 0)]), || {
            let r: StrictReading = strict_read().unwrap();
            assert!(r.generation <= generation());
            assert_eq!(r.micros, 1_000_000);
        });
    }

    // ---- conversion --------------------------------------------------

    #[test]
    fn linux_conversion_floors_and_checks_domain() {
        assert_eq!(
            RawSample::Linux { sec: 1, nsec: 999 }.to_micros(),
            Ok(1_000_000)
        );
        assert_eq!(
            RawSample::Linux {
                sec: 1,
                nsec: 1_999
            }
            .to_micros(),
            Ok(1_000_001)
        );
        assert_eq!(
            RawSample::Linux { sec: -1, nsec: 0 }.to_micros(),
            Err(ClockFault::InvalidRaw)
        );
        assert_eq!(
            RawSample::Linux {
                sec: 0,
                nsec: 1_000_000_000
            }
            .to_micros(),
            Err(ClockFault::InvalidRaw)
        );
        assert_eq!(
            RawSample::Linux { sec: 0, nsec: -1 }.to_micros(),
            Err(ClockFault::InvalidRaw)
        );
    }

    #[test]
    fn linux_conversion_narrowing_boundary() {
        // Largest sec whose micros still fit i64.
        let max_sec = i64::MAX / 1_000_000;
        let rem = i64::MAX % 1_000_000;
        let ok = RawSample::Linux {
            sec: max_sec,
            nsec: rem * 1_000,
        };
        assert_eq!(ok.to_micros(), Ok(max_sec * 1_000_000 + rem));
        let over = RawSample::Linux {
            sec: max_sec,
            nsec: (rem + 1) * 1_000,
        };
        assert_eq!(over.to_micros(), Err(ClockFault::ConversionOverflow));
        assert_eq!(
            RawSample::Linux {
                sec: i64::MAX,
                nsec: 0
            }
            .to_micros(),
            Err(ClockFault::ConversionOverflow)
        );
    }

    #[test]
    fn apple_conversion_scales_and_checks_timebase() {
        // Apple Silicon timebase 125/3: 24 ticks = 1000 ns = 1 us.
        assert_eq!(
            RawSample::Apple {
                ticks: 24,
                numer: 125,
                denom: 3
            }
            .to_micros(),
            Ok(1)
        );
        assert_eq!(
            RawSample::Apple {
                ticks: 23,
                numer: 125,
                denom: 3
            }
            .to_micros(),
            Ok(0)
        );
        // Intel 1/1: nanoseconds directly.
        assert_eq!(
            RawSample::Apple {
                ticks: 2_999,
                numer: 1,
                denom: 1
            }
            .to_micros(),
            Ok(2)
        );
        assert_eq!(
            RawSample::Apple {
                ticks: 1,
                numer: 0,
                denom: 1
            }
            .to_micros(),
            Err(ClockFault::InvalidRaw)
        );
        assert_eq!(
            RawSample::Apple {
                ticks: 1,
                numer: 1,
                denom: 0
            }
            .to_micros(),
            Err(ClockFault::InvalidRaw)
        );
    }

    #[test]
    fn apple_conversion_extreme_inputs_do_not_wrap() {
        // u64::MAX ticks at 1/1 -> 1.8e13 us: fits i64.
        assert_eq!(
            RawSample::Apple {
                ticks: u64::MAX,
                numer: 1,
                denom: 1
            }
            .to_micros(),
            Ok(i64::try_from(u128::from(u64::MAX) / 1_000).unwrap())
        );
        // u64::MAX ticks * u32::MAX / 1 -> 7.9e28 ns -> 7.9e25 us: exceeds i64.
        assert_eq!(
            RawSample::Apple {
                ticks: u64::MAX,
                numer: u32::MAX,
                denom: 1
            }
            .to_micros(),
            Err(ClockFault::ConversionOverflow)
        );
    }

    #[test]
    fn windows_conversion_floors_and_fits() {
        assert_eq!(RawSample::Windows { hundred_ns: 19 }.to_micros(), Ok(1));
        assert_eq!(RawSample::Windows { hundred_ns: 0 }.to_micros(), Ok(0));
        // u64::MAX / 10 < i64::MAX, so Windows cannot overflow.
        assert_eq!(
            RawSample::Windows {
                hundred_ns: u64::MAX
            }
            .to_micros(),
            Ok(i64::try_from(u64::MAX / 10).unwrap())
        );
    }

    #[test]
    fn raw_sample_backend_is_carried_into_reading() {
        with_raw_override(
            scripted(vec![
                Ok(RawSample::Apple {
                    ticks: 24,
                    numer: 125,
                    denom: 3,
                }),
                Ok(RawSample::Windows { hundred_ns: 10 }),
            ]),
            || {
                assert_eq!(
                    strict_read().map(|r| (r.micros, r.backend)),
                    Ok((1, ClockBackend::AppleContinuous))
                );
                assert_eq!(
                    strict_read().map(|r| (r.micros, r.backend)),
                    Ok((1, ClockBackend::WindowsInterruptTime))
                );
            },
        );
    }

    #[test]
    fn override_is_thread_local_and_restored() {
        with_raw_override(scripted(vec![Err(ClockFault::Unsupported)]), || {
            assert_eq!(strict_read(), Err(ClockFault::Unsupported));
            let other =
                std::thread::spawn(|| strict_read().is_ok() || platform_backend().is_none());
            assert!(
                other.join().unwrap(),
                "override must not leak to other threads"
            );
        });
        match platform_backend() {
            Some(_) => assert!(strict_read().is_ok(), "seam must be restored"),
            None => assert_eq!(strict_read(), Err(ClockFault::Unsupported)),
        }
    }
}
