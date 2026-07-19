// Public sleep-aware monotonic clock for `package:nts`.
//
// Wraps the synchronous `ntsBoottimeMicros` bridge call (CLOCK_BOOTTIME
// on Android/Linux, mach_continuous_time on iOS/macOS, interrupt time
// on Windows), which keeps counting across device deep sleep — unlike
// `Stopwatch`, whose underlying clock (CLOCK_MONOTONIC /
// mach_absolute_time) freezes while suspended.
//
// Exported from `lib/nts.dart`: consumers can share the exact
// monotonic timeline the package uses internally via
// `MonotonicClock.instance`.

import '../ffi/api/nts.dart' as ffi;

/// A sleep-aware monotonic time source.
///
/// Although namespaced within `package:nts`, this is a general-purpose
/// monotonic primitive: readings keep advancing while the device is in
/// deep sleep / system suspend, unlike Dart's [Stopwatch], whose
/// underlying clock (`CLOCK_MONOTONIC` / `mach_absolute_time`) freezes
/// while suspended.
///
/// Platform backends (read through the package's Rust core):
///
/// - **Android / Linux:** `clock_gettime(CLOCK_BOOTTIME)`
/// - **iOS / macOS:** `mach_continuous_time` (scaled by the cached
///   `mach_timebase_info`)
/// - **Windows:** `QueryInterruptTimePrecise` (interrupt time includes
///   sleep/hibernation; 100 ns units)
///
/// Each instance resolves its source exactly once, at construction:
/// one probe call of the bridge function decides between the
/// sleep-aware native clock and a plain [Stopwatch] fallback. The
/// source never changes for the instance's lifetime, so readings from
/// one instance are always mutually comparable and never mix epochs.
/// Never compare readings taken from two different instances.
///
/// **Fallback:** if the instance is constructed (or [instance] first
/// accessed) before `NtsRustLib.init()` has completed — or in a
/// pure-Dart context with no bridge at all — the probe throws and the
/// instance permanently degrades to a standard, suspend-frozen
/// [Stopwatch] source. Initialize the bridge before first access to
/// get the sleep-aware source.
///
/// The epoch is arbitrary (per-boot for the native sources); only
/// differences between readings from the same instance are
/// meaningful. Values are not comparable across processes or reboots.
/// Reboot is the only event that resets the native epoch; it also
/// destroys every in-process object, so persisted raw readings from
/// a previous boot are meaningless in any later boot session.
class MonotonicClock {
  /// Shared instance for the current isolate.
  ///
  /// Lazily constructed — and its source resolved — on first access.
  /// The package's own internals (`NtsSyncedTime`, the `getTime`
  /// timeout budget, bridge-slot admission) all read this instance,
  /// so consumer code reading it shares one consistent monotonic
  /// timeline with the package. Like all Dart statics it is
  /// per-isolate: each isolate gets its own lazily resolved instance
  /// (all reading the same underlying native clock when the bridge is
  /// initialized, but do not compare raw readings across isolates —
  /// a fallback-sourced isolate uses a different epoch).
  static final MonotonicClock instance = MonotonicClock();

  final int Function() _read;

  /// Resolve the time source and capture it for this instance.
  MonotonicClock() : _read = _resolveSource();

  static int Function() _resolveSource() {
    try {
      // Probe: throws StateError if the bridge is not initialized, or
      // UnsupportedError from a mock whose `noSuchMethod` rejects
      // unstubbed calls. Any throw selects the fallback.
      ffi.ntsBoottimeMicros();
      return () => ffi.ntsBoottimeMicros().toInt();
    } catch (_) {
      final sw = Stopwatch()..start();
      return () => sw.elapsedMicroseconds;
    }
  }

  /// Current reading in microseconds since an arbitrary epoch. Only
  /// differences between readings from the same instance are
  /// meaningful.
  int nowMicros() => _read();

  /// Elapsed time since [startMicros] (an earlier [nowMicros] reading
  /// from this same instance).
  Duration elapsedSince(int startMicros) =>
      Duration(microseconds: nowMicros() - startMicros);
}
