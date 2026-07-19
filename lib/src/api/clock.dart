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
import '../ffi/frb_generated.dart' show NtsRustLib, NtsRustLibApiImpl;

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
/// Each instance resolves its source exactly once, at construction.
/// The source never changes for the instance's lifetime, so readings
/// from one instance are always mutually comparable and never mix
/// epochs. Never compare readings taken from two different instances.
///
/// **Initialization is required:** constructing an instance (or first
/// accessing [instance]) before `NtsRustLib.init()` (or
/// `NtsRustLib.initMock()`) has completed throws a [StateError]. The
/// silent suspend-frozen [Stopwatch] fallback that existed before
/// v7.0.0 has been removed for uninitialized processes — a production
/// build can no longer silently degrade to a clock that freezes
/// during device sleep.
///
/// **Mock-mode fallback (tests only):** when the bridge was
/// initialized via `NtsRustLib.initMock()` with an API that does not
/// stub `crateApiNtsNtsBoottimeMicros`, the probe call throws and the
/// instance degrades to a standard, suspend-frozen [Stopwatch]
/// source. A real bridge (`NtsRustLib.init()` installing the
/// generated FFI implementation) is detected structurally and never
/// takes this path: its clock read is dispatched directly, with no
/// probe and no catch, so any failure propagates instead of being
/// masked by a silent source switch.
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
  /// a mock-fallback-sourced isolate uses a different epoch).
  ///
  /// Accessing this before `NtsRustLib.init()` /
  /// `NtsRustLib.initMock()` throws a [StateError]. Because Dart
  /// re-runs a throwing lazy-static
  /// initializer on the next access, the singleton is not poisoned:
  /// the first access *after* bridge init resolves normally.
  static final MonotonicClock instance = MonotonicClock();

  final int Function() _read;

  /// Resolve the time source and capture it for this instance.
  ///
  /// Throws [StateError] when the bridge has not been initialized;
  /// see the class doc for the mock-mode [Stopwatch] fallback.
  MonotonicClock() : _read = _resolveSource();

  static int Function() _resolveSource() {
    if (!NtsRustLib.instance.initialized) {
      throw StateError(
        'MonotonicClock requires the nts bridge: call '
        '`await NtsRustLib.init()` (or `NtsRustLib.initMock()` in '
        'tests) before constructing a MonotonicClock or accessing '
        'MonotonicClock.instance.',
      );
    }
    // `api` is FRB-internal, but this package owns the generated
    // bindings; the same access pattern is used throughout
    // `lib/src/ffi/api/nts.dart`.
    // ignore: invalid_use_of_internal_member
    if (NtsRustLib.instance.api is NtsRustLibApiImpl) {
      // Real bridge (`NtsRustLib.init()` installed the generated FFI
      // dispatch implementation): no probe, no catch. Any failure of
      // the synchronous clock read propagates instead of being masked
      // by a silent switch to a suspend-frozen source.
      return () => ffi.ntsBoottimeMicros().toInt();
    }
    try {
      // Mock mode (`NtsRustLib.initMock()`, or a hand-supplied API
      // passed to `init()`): probe once. A throw (e.g.
      // UnsupportedError from a fake whose `noSuchMethod` rejects
      // unstubbed calls) selects the suspend-frozen test fallback.
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
