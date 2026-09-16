// Error hierarchy for the strict clock. Part of strict_clock.dart.
//
// Every failure a `StrictClockContext` can raise is a subtype of the
// sealed `StrictClockError`, so a caller can exhaustively `switch` on
// it. None of these carry generated FFI types.

part of 'strict_clock.dart';

/// Base of every strict clock failure. Sealed: `switch` over it is
/// exhaustive.
///
/// Most subtypes are thrown by [StrictClockContext.resolve],
/// [StrictClockContext.now] and [StrictClockContext.elapsedSince], and
/// by the [StrictSyncedTime] constructor's anchor check. Three arise
/// only while a call acquires a query sample and reach the caller as
/// the `fault` of an `NtsError.clockFault` rather than directly, and
/// they differ in which surfaces can raise them:
///
/// - [StrictClockSuspendedInFlight], at `ClockFaultStage.receipt`, is
///   the native core's per-sample verdict that the device slept between
///   send and receive. The core runs that check for every caller, so
///   `ntsQuery` surfaces it with or without a `context`, and `ntsGetTime`
///   and `ntsGetTimeStrict` both tolerate it per sample and rethrow it
///   only when no sample in the burst landed.
/// - [StrictClockMissingReceipt] and [StrictClockForeignReceipt], at
///   `ClockFaultStage.attribution`, are raised only by a strict
///   acquisition (`ntsGetTimeStrict`, `NtsClient.getTimeStrict`)
///   attributing a sample to its context; the legacy surfaces never
///   attribute, so never raise them.
///
/// The other subtypes are carried the same way when the failing read
/// was one the acquisition made on the caller's behalf.
///
/// [StrictClockContext.resolveForTesting] throws the same errors once
/// past its precondition; the [StateError] it throws when the bridge is
/// not a mock is a test-setup error, not a clock failure, and is not
/// part of this hierarchy.
sealed class StrictClockError implements Exception {
  const StrictClockError._();

  /// Human-readable explanation. A failure is only ever thrown, never
  /// returned in place of a reading; readings quoted here (as in
  /// [StrictClockRegression]) are diagnostic, not a substitute value.
  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The bridge holds nothing; `NtsBridge.ensureInitialized` has not
/// completed on this isolate.
final class StrictClockUninitialized extends StrictClockError {
  /// Construct the error.
  const StrictClockUninitialized() : super._();

  @override
  String get message =>
      'the nts bridge is not initialized on this isolate; await '
      'NtsBridge.ensureInitialized() before StrictClockContext.resolve()';
}

/// The bridge holds a hand-written test double, which cannot supply a
/// native strict clock. Use [StrictClockContext.resolveForTesting].
final class StrictClockMockOnly extends StrictClockError {
  /// Construct the error.
  const StrictClockMockOnly() : super._();

  @override
  String get message =>
      'the nts bridge holds a mock api; StrictClockContext.resolve() '
      'requires the generated native bridge (use resolveForTesting in tests)';
}

/// This build has no supported suspend-inclusive backend (web, or a
/// platform outside Android, iOS, macOS, Linux and Windows).
final class StrictClockUnsupported extends StrictClockError {
  /// Construct the error.
  const StrictClockUnsupported() : super._();

  @override
  String get message =>
      'no supported suspend-inclusive clock backend on this platform';
}

/// Category of a [StrictClockSourceFault].
enum SourceFaultKind {
  /// `clock_gettime(CLOCK_BOOTTIME)` returned non-zero.
  syscallFailed,

  /// `mach_timebase_info` failed or returned a zero ratio.
  timebaseUnavailable,

  /// A raw native field was outside its documented domain.
  invalidRaw,

  /// The checked scale or narrowing to microseconds overflowed.
  conversionOverflow,

  /// The loaded native library and these Dart bindings disagree on
  /// the wire layout of the value crossing the FFI boundary (the
  /// generated decoder threw). Rebuild the native library from the
  /// Rust sources matching this package version; resolving a new
  /// context does not help. The same classification the query entry
  /// points report as `NtsError.abiMismatch`. Only reported by a
  /// context with [StrictClockProvenance.native]; no decoder runs
  /// behind a test double.
  abiMismatch,

  /// The bridge threw something that is not a typed clock fault and
  /// not a decode failure: a missing symbol, a disposed entrypoint,
  /// or — on a [StrictClockProvenance.testInjected] context — any
  /// untyped throw from the double, including an unstubbed method.
  bridge,
}

/// A native read (or the bridge carrying it) failed.
///
/// [errno] is present exactly when [kind] is
/// [SourceFaultKind.syscallFailed]. The public constructor enforces
/// this at runtime in every build mode, so a `switch` on [kind] can
/// rely on the payload's shape.
final class StrictClockSourceFault extends StrictClockError {
  /// Construct the error. [errno] is required for
  /// [SourceFaultKind.syscallFailed] and must be omitted for every
  /// other [kind]; any other combination throws [ArgumentError].
  factory StrictClockSourceFault({
    required SourceFaultKind kind,
    required String detail,
    int? errno,
  }) {
    if ((kind == SourceFaultKind.syscallFailed) != (errno != null)) {
      throw ArgumentError.value(
        errno,
        'errno',
        'required for SourceFaultKind.syscallFailed and not permitted for '
            'any other kind (kind: ${kind.name})',
      );
    }
    return StrictClockSourceFault._(kind: kind, detail: detail, errno: errno);
  }

  /// Library-internal: every call site pairs [kind] and [errno] as
  /// the public constructor requires.
  const StrictClockSourceFault._({
    required this.kind,
    required String detail,
    this.errno,
  }) : _detail = detail,
       super._();

  /// What failed.
  final SourceFaultKind kind;

  /// `errno` for [SourceFaultKind.syscallFailed]; `null` for every
  /// other [kind].
  final int? errno;

  final String _detail;

  @override
  String get message => 'strict clock source fault (${kind.name}): $_detail';
}

/// A fresh reading came back strictly below an earlier one on the
/// same coordinate and generation: this context's own previous
/// reading, or the `earlier` handed to
/// [StrictClockContext.elapsedSince], which may come from another
/// context. Invalidates the context that observed it.
final class StrictClockRegression extends StrictClockError {
  /// Construct the error.
  const StrictClockRegression({required this.previous, required this.observed})
    : super._();

  /// The earlier, higher reading in microseconds.
  final int previous;

  /// The later, lower reading in microseconds.
  final int observed;

  @override
  String get message =>
      'strict clock regressed from $previous to $observed microseconds';
}

/// The context is no longer usable; see [reason].
final class StrictClockInvalidated extends StrictClockError {
  /// Construct the error.
  const StrictClockInvalidated({required this.generation, required this.reason})
    : super._();

  /// Generation the invalidated context was bound to.
  final int generation;

  /// Why the context is invalid.
  final StrictClockInvalidationReason reason;

  @override
  String get message =>
      'strict clock context on generation $generation is invalid '
      '(${reason.name}); resolve a new context';
}

/// A successful read named a backend other than the one the context
/// was resolved on.
final class StrictClockUnknownSource extends StrictClockError {
  /// Construct the error.
  const StrictClockUnknownSource({
    required this.expected,
    required this.observed,
  }) : super._();

  /// Backend the context's descriptor names.
  final ClockBackend expected;

  /// Backend the reading reported.
  final ClockBackend observed;

  @override
  String get message =>
      'strict clock read came from ${observed.name}, context is bound to '
      '${expected.name}';
}

/// A reading taken through a different bridge incarnation was passed
/// to a context: the native bridge versus a mock, two mock doubles
/// installed in turn, or the same double before and after a reset. Each
/// incarnation runs its own counter and reports its own descriptor, so
/// even an equal generation and descriptor do not make the reading
/// comparable. Checked before the descriptor and generation, and like
/// them it does not invalidate the receiving context. [expected] and
/// [actual] may be equal: two mocks are both `testInjected`.
final class StrictClockSourceIncompatible extends StrictClockError {
  /// Construct the error.
  const StrictClockSourceIncompatible({
    required this.expected,
    required this.actual,
  }) : super._();

  /// Provenance of the context.
  final StrictClockProvenance expected;

  /// Provenance of the reading that was offered.
  final StrictClockProvenance actual;

  @override
  String get message =>
      'reading was taken through a ${actual.name} bridge incarnation '
      'other than the ${expected.name} one this context is bound to';
}

/// A reading on an incompatible coordinate was passed to a context.
final class StrictClockDescriptorIncompatible extends StrictClockError {
  /// Construct the error.
  const StrictClockDescriptorIncompatible({
    required this.expected,
    required this.actual,
  }) : super._();

  /// Descriptor of the context.
  final ClockSourceDescriptor expected;

  /// Descriptor of the reading that was offered.
  final ClockSourceDescriptor actual;

  @override
  String get message =>
      'reading on $actual is not comparable with a context on $expected';
}

/// A reading from another generation was passed to a context. The
/// coordinate is compatible, but the two were not taken under one
/// counter epoch, so the difference is meaningless. The receiving
/// context is not invalidated: a foreign reading is the caller's
/// error, not evidence against the source, and neither generation is
/// being declared dead — [actual] may even be the live one when an
/// older context is handed a newer reading.
final class StrictClockGenerationIncompatible extends StrictClockError {
  /// Construct the error.
  const StrictClockGenerationIncompatible({
    required this.expected,
    required this.actual,
  }) : super._();

  /// Generation the context is bound to.
  final int expected;

  /// Generation the offered reading was taken under.
  final int actual;

  @override
  String get message =>
      'reading on generation $actual is not comparable with a context on '
      'generation $expected';
}

/// The device suspended while an NTP reply was in flight.
///
/// The Rust core brackets every UDP send/recv pair with strict
/// readings; when the sleep-aware span exceeds the monotonic round
/// trip by more than the tolerance, the round trip under-measures the
/// network delay and the sample is rejected. This is a per-sample
/// verdict, not a clock fault: the context that observed it stays
/// valid and the remediation is to retry the query. Only ever carried
/// as the `fault` of an `NtsError.clockFault`.
final class StrictClockSuspendedInFlight extends StrictClockError {
  /// Construct the error.
  const StrictClockSuspendedInFlight({
    required this.boottimeMicros,
    required this.monotonicMicros,
  }) : super._();

  /// Sleep-aware span from just before the send to just after the
  /// recv, in microseconds.
  final int boottimeMicros;

  /// Monotonic round trip measured across the same interval.
  final int monotonicMicros;

  @override
  String get message =>
      'device suspended while the NTP reply was in flight: sleep-aware '
      'span $boottimeMicros us against a monotonic round trip of '
      '$monotonicMicros us';
}

/// A sample carried no strict receipt stamp.
///
/// `NtsTimeSample.recvClockGeneration` is `0`, which no build of the
/// Rust core produces — the live generation starts at `1` — so the
/// sample was hand-built or crossed a bridge that does not stamp
/// receipts. A strict acquisition rejects it rather than ageing a
/// stamp with no provenance; a later successful strict read cannot
/// certify it after the fact.
final class StrictClockMissingReceipt extends StrictClockError {
  /// Construct the error.
  const StrictClockMissingReceipt() : super._();

  @override
  String get message =>
      'sample carries no strict receipt stamp (recvClockGeneration 0) and '
      'cannot be attributed to a strict clock context';
}

/// A sample's receipt stamp was taken under a generation or backend
/// other than the strict context's.
///
/// The stamp may be numerically plausible; attribution is by
/// generation and backend, never by plausibility. A foreign stamp
/// cannot be aged against the context's readings, so the strict
/// acquisition fails rather than substituting a Dart-side arrival
/// time.
final class StrictClockForeignReceipt extends StrictClockError {
  /// Construct the error.
  const StrictClockForeignReceipt({
    required this.expectedGeneration,
    required this.observedGeneration,
    required this.expectedBackend,
    required this.observedBackend,
  }) : super._();

  /// Generation the context is bound to.
  final int expectedGeneration;

  /// Generation the sample's receipt stamp was read under.
  final int observedGeneration;

  /// Backend the context's descriptor names.
  final ClockBackend expectedBackend;

  /// Backend the sample's receipt stamp was read from, or `null` when
  /// the sample carries none.
  final ClockBackend? observedBackend;

  @override
  String get message =>
      'sample receipt stamp is foreign to the strict clock context: '
      'generation $observedGeneration on '
      '${observedBackend?.name ?? 'no backend'} against context generation '
      '$expectedGeneration on ${expectedBackend.name}';
}
