// Public strict sleep-aware clock for `package:nts`.
//
// `MonotonicClock` (clock.dart) is the legacy best-effort primitive:
// its readings carry no provenance, the Rust side may have degraded
// to a suspend-frozen process-local counter, and in mock mode it
// falls back to `Stopwatch`. The types here are the strict,
// provenance-attributed alternative described by the `nts-flr8`
// contract: a `StrictClockContext` is resolved explicitly, names its
// `ClockSourceDescriptor`, is bound to a live generation, and either
// returns a `StrictReading` or throws a `StrictClockError` on that
// call. A fault, a bridge reset, or a native generation change
// invalidates the context permanently; explicit re-resolution yields
// a new context and never repairs the old one.
//
// Consumers never import generated FFI types: every FFI value is
// converted at this boundary.

import 'package:meta/meta.dart' show visibleForTesting;

import '../ffi/api/nts.dart' as ffi;
import '../ffi/frb_generated.dart' show NtsRustLib;
import 'bridge.dart';

part 'strict_clock_errors.dart';

/// Native suspend-inclusive clock source family.
enum ClockBackend {
  /// `clock_gettime(CLOCK_BOOTTIME)` — Android, Linux.
  linuxBoottime,

  /// `mach_continuous_time` scaled by `mach_timebase_info` — iOS, macOS.
  appleContinuous,

  /// `QueryInterruptTimePrecise` — Windows.
  windowsInterruptTime,
}

/// Versioned description of a strict clock coordinate.
///
/// Fixed semantics for [semanticsVersion] `1`: the origin is an
/// arbitrary instant of the current counter epoch (per boot on every
/// supported platform), `0` is a valid reading, the unit is
/// microseconds floored from the native unit, and the range is
/// `0..=2^63-1`. Two descriptors are compatible iff [backend],
/// [semanticsVersion] and [conversionVersion] are all equal — the
/// package version is not an input, and compatibility says nothing
/// about whether two readings share a counter epoch (see
/// [StrictClockContext.generation]).
final class ClockSourceDescriptor {
  /// Construct a descriptor. Production code obtains one from
  /// [StrictClockContext.descriptor]; constructing one by hand only
  /// makes sense for compatibility checks against persisted metadata.
  const ClockSourceDescriptor({
    required this.backend,
    required this.semanticsVersion,
    required this.conversionVersion,
  });

  /// Source family the coordinate is read from.
  final ClockBackend backend;

  /// Coordinate semantics version (origin rule, unit, range,
  /// comparison rules). Currently `1`.
  final int semanticsVersion;

  /// Raw-to-microsecond conversion rule version. Currently `1`.
  final int conversionVersion;

  /// Whether readings on this coordinate and on [other] can be
  /// compared once a shared counter epoch has been established by
  /// other means.
  bool isCompatibleWith(ClockSourceDescriptor other) =>
      backend == other.backend &&
      semanticsVersion == other.semanticsVersion &&
      conversionVersion == other.conversionVersion;

  @override
  bool operator ==(Object other) =>
      other is ClockSourceDescriptor && isCompatibleWith(other);

  @override
  int get hashCode => Object.hash(backend, semanticsVersion, conversionVersion);

  @override
  String toString() =>
      'ClockSourceDescriptor(backend: ${backend.name}, '
      'semanticsVersion: $semanticsVersion, '
      'conversionVersion: $conversionVersion)';
}

/// How a [StrictClockContext] was resolved.
enum StrictClockProvenance {
  /// Resolved through the generated FFI dispatch against the Rust
  /// core: readings come from the native backend the descriptor
  /// names. The only provenance a production path may accept.
  native,

  /// Resolved through a hand-written mock bridge in a test. The
  /// readings are whatever the test supplied; the context exists so
  /// lifecycle and arithmetic can be exercised without a dylib. Never
  /// portable, never production.
  testInjected,
}

/// A successful strict reading: a coordinate plus the generation and
/// descriptor it is only meaningful under.
final class StrictReading {
  const StrictReading._({
    required this.micros,
    required this.generation,
    required this.descriptor,
  });

  /// Microseconds on [descriptor]'s coordinate. `0` is valid.
  final int micros;

  /// Live generation the reading was taken under. Readings are only
  /// comparable when their generations are equal.
  final int generation;

  /// Coordinate the reading is on.
  final ClockSourceDescriptor descriptor;

  @override
  bool operator ==(Object other) =>
      other is StrictReading &&
      micros == other.micros &&
      generation == other.generation &&
      descriptor == other.descriptor;

  @override
  int get hashCode => Object.hash(micros, generation, descriptor);

  @override
  String toString() =>
      'StrictReading(micros: $micros, generation: $generation, '
      'descriptor: $descriptor)';
}

/// Why a [StrictClockContext] stopped being usable.
enum StrictClockInvalidationReason {
  /// A native read faulted (`syscallFailed`, `timebaseUnavailable`,
  /// `invalidRaw`, `conversionOverflow`) or the bridge threw something
  /// that is not a typed fault.
  sourceFault,

  /// A read on this context came back strictly below the previous one.
  regression,

  /// The Rust core's live generation moved: another context, thread
  /// or engine observed a fault or invalidated the clock.
  nativeGeneration,

  /// The bridge was disposed, reset or re-initialized on this isolate
  /// since the context was resolved (`NtsBridge.dispose()`, the raw
  /// `NtsRustLib.dispose()`, `debugReset()`, or a fresh `init()`).
  bridgeReset,

  /// A successful read reported a backend other than the one the
  /// context's descriptor names.
  unknownSource,

  /// [StrictClockContext.invalidate] was called.
  explicit,
}

/// A resolved strict clock: one explicit source coordinate, one live
/// generation, fail-closed reads.
///
/// Obtain one with [resolve]. Every [now] either returns a
/// [StrictReading] on this context's [descriptor] under this
/// context's [generation], or throws a [StrictClockError] on that
/// call and leaves the context permanently invalid ([isValid] is
/// `false`; every later call throws [StrictClockInvalidated]). There
/// is no `Stopwatch`, `Instant` or RTC fallback, no clamping, and no
/// deferred notification.
///
/// **Generation is a lifecycle token, not an identity.** Two contexts
/// on the same isolate resolved back-to-back share a generation; two
/// processes on the same boot do not. Equality of generations proves
/// nothing across processes and is not required for compatibility
/// (see [ClockSourceDescriptor.isCompatibleWith]).
///
/// **Lifecycle.** The context checks, on every read and before any
/// FFI call: that [NtsBridge.state] still matches its
/// [provenance]; that the entrypoint still holds the API object it
/// was resolved against (so a raw `NtsRustLib.dispose()` + `init()`
/// is caught even though it bypasses [NtsBridge], because `init()`
/// builds a fresh API object); and that [NtsBridge.dispose] /
/// `debugReset` have not run since. After the FFI call it checks the
/// reading's generation and backend, and its monotonicity against
/// this context's own previous reading. Equal consecutive readings
/// are valid.
///
/// One raw sequence is outside that coverage: `NtsRustLib.dispose()`
/// followed by `initMock(api:)` with the *same* API object. The
/// entrypoint exposes no per-installation token, so state, identity
/// and epoch all read as unchanged and a context resolved before it
/// keeps reading through the reinstalled double. That is the caller
/// asserting the double's lifecycle is continuous; tear down through
/// [NtsBridge.dispose] instead when a reset should be observed.
///
/// **Other engines.** Dart statics are per isolate, so contexts in
/// another isolate or engine are unaffected by this isolate's
/// bookkeeping. The Rust generation is process-wide: a native fault,
/// a regression, or a [NtsBridge.dispose] on any isolate advances it,
/// and every context in the process fails closed on its next read
/// rather than continuing on a source that just misbehaved.
///
/// **No I/O.** [now] performs the bridge-state checks and one
/// synchronous clock read; it never touches persistence, the network
/// or any boot-identity provider.
final class StrictClockContext {
  StrictClockContext._({
    required this.descriptor,
    required this.generation,
    required this.provenance,
    required Object boundApi,
    required int bridgeEpoch,
  }) : _boundApi = boundApi,
       _bridgeEpoch = bridgeEpoch;

  /// Per-isolate count of bridge resets seen by [NtsBridge]. Compared
  /// against the value captured at resolution.
  static int _isolateBridgeEpoch = 0;

  /// Coordinate every reading from this context is on.
  final ClockSourceDescriptor descriptor;

  /// Live generation this context is bound to.
  final int generation;

  /// How this context was resolved.
  final StrictClockProvenance provenance;

  final Object _boundApi;
  final int _bridgeEpoch;
  int? _last;
  StrictClockInvalidationReason? _invalidated;

  /// Whether this context has been observed to be invalid. Once
  /// `false`, never `true` again.
  ///
  /// Reflects only invalidations this object has seen: an explicit
  /// [invalidate], or a [now] / [elapsedSince] that threw. It is not a
  /// liveness probe — after [NtsBridge.dispose], `debugReset`, or a
  /// native generation advance from another isolate or engine, this
  /// stays `true` until the next read performs the lifecycle and
  /// generation checks and fails. Call [now] to learn the current
  /// state.
  bool get isValid => _invalidated == null;

  /// Why this context is invalid, or `null` while it is valid.
  ///
  /// Same observed-only semantics as [isValid]: `null` means no call
  /// on this object has failed yet, not that the underlying source
  /// and bridge are still the ones it was resolved against.
  StrictClockInvalidationReason? get invalidationReason => _invalidated;

  /// Resolve a strict context against the native bridge.
  ///
  /// Throws [StrictClockUninitialized] when the bridge holds nothing,
  /// [StrictClockMockOnly] when it holds a hand-written double (use
  /// [resolveForTesting] there), [StrictClockUnsupported] when the
  /// build has no supported backend, and the read's own error when
  /// the binding read faults. Performs one strict read to bind the
  /// generation and to confirm the read backend matches the
  /// descriptor. Never cached: each call is a fresh resolution.
  static StrictClockContext resolve() {
    switch (NtsBridge.state) {
      case NtsBridgeState.uninitialized:
        throw const StrictClockUninitialized();
      case NtsBridgeState.mock:
        throw const StrictClockMockOnly();
      case NtsBridgeState.native:
        return _resolve(StrictClockProvenance.native);
    }
  }

  /// Resolve a context through a hand-written mock bridge.
  ///
  /// For tests only. Requires [NtsBridge.state] to be
  /// [NtsBridgeState.mock]; the resulting context has
  /// [provenance] [StrictClockProvenance.testInjected] and its
  /// readings are whatever the double's `crateApiNtsNtsStrictClockRead`
  /// returns. Throws [StateError] against an uninitialized or native
  /// bridge so a native context can never be relabelled and a test
  /// double can never be labelled native.
  @visibleForTesting
  static StrictClockContext resolveForTesting() {
    if (NtsBridge.state != NtsBridgeState.mock) {
      throw StateError(
        'StrictClockContext.resolveForTesting requires a mock bridge '
        '(NtsRustLib.initMock with a hand-written api); the bridge is '
        '${NtsBridge.state.name}.',
      );
    }
    return _resolve(StrictClockProvenance.testInjected);
  }

  static StrictClockContext _resolve(StrictClockProvenance provenance) {
    // ignore: invalid_use_of_internal_member
    final api = NtsRustLib.instance.api;
    final epoch = _isolateBridgeEpoch;
    final descriptor = _guard(
      () => _descriptorFrom(ffi.ntsClockDescriptor()),
      provenance,
    );
    final reading = _guard(ffi.ntsStrictClockRead, provenance);
    final backend = _backendFrom(reading.backend);
    if (backend != descriptor.backend) {
      throw StrictClockUnknownSource(
        expected: descriptor.backend,
        observed: backend,
      );
    }
    final ctx = StrictClockContext._(
      descriptor: descriptor,
      generation: reading.generation.toInt(),
      provenance: provenance,
      boundApi: api,
      bridgeEpoch: epoch,
    );
    ctx._last = reading.micros.toInt();
    return ctx;
  }

  /// Current reading on this context's coordinate.
  ///
  /// Throws [StrictClockInvalidated] if the context is already
  /// invalid, and otherwise a [StrictClockError] describing the fault
  /// that just invalidated it. Equal consecutive readings are valid.
  StrictReading now() {
    _checkLifecycle();
    return _read();
  }

  StrictReading _read() {
    final ffi.NtsStrictClockReading raw;
    try {
      raw = ffi.ntsStrictClockRead();
    } on ffi.NtsClockFault catch (fault) {
      throw _fail(
        _mapFault(fault, boundGeneration: generation),
        _reasonFor(fault),
      );
    } catch (error) {
      throw _fail(
        _bridgeFault(error, provenance),
        StrictClockInvalidationReason.sourceFault,
      );
    }
    final gen = raw.generation.toInt();
    if (gen != generation) {
      throw _fail(
        StrictClockInvalidated(
          generation: generation,
          reason: StrictClockInvalidationReason.nativeGeneration,
        ),
        StrictClockInvalidationReason.nativeGeneration,
      );
    }
    final backend = _backendFrom(raw.backend);
    if (backend != descriptor.backend) {
      throw _fail(
        StrictClockUnknownSource(
          expected: descriptor.backend,
          observed: backend,
        ),
        StrictClockInvalidationReason.unknownSource,
      );
    }
    final micros = raw.micros.toInt();
    final previous = _last;
    if (previous != null && micros < previous) {
      // Advance the process-wide generation too: a backwards source
      // is not trustworthy for anyone, not just this context.
      _tryNativeInvalidate();
      throw _fail(
        StrictClockRegression(previous: previous, observed: micros),
        StrictClockInvalidationReason.regression,
      );
    }
    _last = micros;
    return StrictReading._(
      micros: micros,
      generation: generation,
      descriptor: descriptor,
    );
  }

  /// Elapsed time from [earlier] to a fresh reading on this context.
  ///
  /// The context's own lifecycle is checked first: an already-invalid
  /// context throws [StrictClockInvalidated] with its stored reason
  /// whatever [earlier] is, and a bridge reset is reported the same
  /// way [now] reports it. Only then is [earlier] examined: it must be
  /// a reading on this context's coordinate (compatible descriptor)
  /// and generation, otherwise [StrictClockDescriptorIncompatible] /
  /// [StrictClockGenerationIncompatible] is thrown without reading the
  /// clock and without invalidating this context — a foreign reading
  /// is the caller's error, not evidence against the source. Because [now]
  /// enforces monotonicity against this context's own sequence, the
  /// fresh reading cannot be below [earlier] unless [earlier] was
  /// taken by a different context on the same generation; that case
  /// is reported as a [StrictClockRegression] and does invalidate.
  Duration elapsedSince(StrictReading earlier) {
    _checkLifecycle();
    _checkReadingBelongs(earlier);
    final current = _read();
    if (current.micros < earlier.micros) {
      _tryNativeInvalidate();
      throw _fail(
        StrictClockRegression(
          previous: earlier.micros,
          observed: current.micros,
        ),
        StrictClockInvalidationReason.regression,
      );
    }
    return Duration(microseconds: current.micros - earlier.micros);
  }

  /// Mark this context invalid. Idempotent; later reads throw
  /// [StrictClockInvalidated] with reason
  /// [StrictClockInvalidationReason.explicit].
  void invalidate() {
    _invalidated ??= StrictClockInvalidationReason.explicit;
  }

  void _checkReadingBelongs(StrictReading reading) {
    if (!reading.descriptor.isCompatibleWith(descriptor)) {
      throw StrictClockDescriptorIncompatible(
        expected: descriptor,
        actual: reading.descriptor,
      );
    }
    if (reading.generation != generation) {
      throw StrictClockGenerationIncompatible(
        expected: generation,
        actual: reading.generation,
      );
    }
  }

  void _checkLifecycle() {
    final reason = _invalidated;
    if (reason != null) {
      throw StrictClockInvalidated(generation: generation, reason: reason);
    }
    final expectedState = switch (provenance) {
      StrictClockProvenance.native => NtsBridgeState.native,
      StrictClockProvenance.testInjected => NtsBridgeState.mock,
    };
    // ignore: invalid_use_of_internal_member
    final entrypoint = NtsRustLib.instance;
    final reset =
        _bridgeEpoch != _isolateBridgeEpoch ||
        NtsBridge.state != expectedState ||
        // ignore: invalid_use_of_internal_member
        !identical(entrypoint.api, _boundApi);
    if (reset) {
      throw _fail(
        StrictClockInvalidated(
          generation: generation,
          reason: StrictClockInvalidationReason.bridgeReset,
        ),
        StrictClockInvalidationReason.bridgeReset,
      );
    }
  }

  StrictClockError _fail(
    StrictClockError error,
    StrictClockInvalidationReason reason,
  ) {
    _invalidated ??= reason;
    return error;
  }

  /// Best-effort native generation bump on a regression seen from
  /// Dart. A double without the stub cannot advance it; the context
  /// is invalidated regardless.
  static void _tryNativeInvalidate() {
    try {
      ffi.ntsClockInvalidate();
    } catch (_) {}
  }

  /// Run a resolution-time FFI call, converting typed faults and
  /// untyped bridge failures into [StrictClockError]s.
  static T _guard<T>(T Function() call, StrictClockProvenance provenance) {
    try {
      return call();
    } on ffi.NtsClockFault catch (fault) {
      throw _mapFault(fault);
    } catch (error) {
      throw _bridgeFault(error, provenance);
    }
  }

  /// Classify an untyped throw from the bridge. On a native bridge,
  /// `RangeError` and `UnimplementedError` are the two shapes the
  /// FRB-generated decoder produces when the loaded library's wire
  /// layout disagrees with these bindings (see the ABI-mismatch notes
  /// in `nts_validation.dart`), so they carry rebuild guidance rather
  /// than being blamed on the clock source. Behind a test double no
  /// decoder runs — those same shapes are an unstubbed or
  /// deliberately failing mock — so every throw stays a generic
  /// bridge fault there, as does anything else on a native bridge.
  static StrictClockSourceFault _bridgeFault(
    Object error,
    StrictClockProvenance provenance,
  ) {
    if (provenance == StrictClockProvenance.native &&
        (error is RangeError || error is UnimplementedError)) {
      return StrictClockSourceFault(
        kind: SourceFaultKind.abiMismatch,
        detail:
            'the loaded native library and these Dart bindings disagree '
            'on the wire layout of a value crossing the FFI boundary '
            '($error) — rebuild the native library from the Rust sources '
            'matching this package version (`cargo build --release` in '
            '`rust/`, then regenerate bindings with '
            '`dart run tool/check_bindings.dart` if the Rust API changed)',
      );
    }
    return StrictClockSourceFault(
      kind: SourceFaultKind.bridge,
      detail: error.toString(),
    );
  }

  static ClockSourceDescriptor _descriptorFrom(ffi.NtsClockDescriptor d) =>
      ClockSourceDescriptor(
        backend: _backendFrom(d.backend),
        semanticsVersion: d.semanticsVersion,
        conversionVersion: d.conversionVersion,
      );

  static ClockBackend _backendFrom(ffi.NtsClockBackend b) => switch (b) {
    ffi.NtsClockBackend.linuxBoottime => ClockBackend.linuxBoottime,
    ffi.NtsClockBackend.appleContinuous => ClockBackend.appleContinuous,
    ffi.NtsClockBackend.windowsInterruptTime =>
      ClockBackend.windowsInterruptTime,
  };

  /// Convert a typed FFI fault. [boundGeneration] is the generation of
  /// the context that made the call, when there is one: a
  /// `generationChanged` fault's `expected` is the live generation the
  /// read began under, not the context's, so the resulting
  /// [StrictClockInvalidated] names the context's own generation. At
  /// resolution time there is no context yet and `expected` stands.
  static StrictClockError _mapFault(
    ffi.NtsClockFault f, {
    int? boundGeneration,
  }) => switch (f) {
    ffi.NtsClockFault_Unsupported() => const StrictClockUnsupported(),
    ffi.NtsClockFault_SyscallFailed(:final errno) => StrictClockSourceFault(
      kind: SourceFaultKind.syscallFailed,
      detail: 'clock_gettime(CLOCK_BOOTTIME) failed, errno $errno',
      errno: errno,
    ),
    ffi.NtsClockFault_TimebaseUnavailable(
      :final kernReturn,
      :final numer,
      :final denom,
    ) =>
      StrictClockSourceFault(
        kind: SourceFaultKind.timebaseUnavailable,
        detail:
            'mach_timebase_info kern_return $kernReturn, '
            'numer $numer, denom $denom',
      ),
    ffi.NtsClockFault_InvalidRaw() => const StrictClockSourceFault(
      kind: SourceFaultKind.invalidRaw,
      detail: 'raw native sample outside its documented domain',
    ),
    ffi.NtsClockFault_ConversionOverflow() => const StrictClockSourceFault(
      kind: SourceFaultKind.conversionOverflow,
      detail: 'checked conversion to i64 microseconds failed',
    ),
    ffi.NtsClockFault_Regression(:final previous, :final observed) =>
      StrictClockRegression(
        previous: previous.toInt(),
        observed: observed.toInt(),
      ),
    ffi.NtsClockFault_GenerationChanged(:final expected) =>
      StrictClockInvalidated(
        generation: boundGeneration ?? expected.toInt(),
        reason: StrictClockInvalidationReason.nativeGeneration,
      ),
  };

  static StrictClockInvalidationReason _reasonFor(ffi.NtsClockFault f) =>
      switch (f) {
        ffi.NtsClockFault_Regression() =>
          StrictClockInvalidationReason.regression,
        ffi.NtsClockFault_GenerationChanged() =>
          StrictClockInvalidationReason.nativeGeneration,
        _ => StrictClockInvalidationReason.sourceFault,
      };
}

/// Bridge-lifecycle hook for [NtsBridge]: records a reset on this
/// isolate so every [StrictClockContext] resolved before it fails
/// closed, and, when the generated bridge is installed, advances the
/// process-wide native generation as well.
///
/// Not part of the public API; [NtsBridge.dispose] and
/// `NtsBridge.debugReset` call it before tearing the entrypoint down.
void noteStrictClockBridgeReset({required bool invalidateNative}) {
  StrictClockContext._isolateBridgeEpoch++;
  if (invalidateNative) {
    StrictClockContext._tryNativeInvalidate();
  }
}
