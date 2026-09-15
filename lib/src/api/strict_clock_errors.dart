// Error hierarchy for the strict clock. Part of strict_clock.dart.
//
// Every failure a `StrictClockContext` can raise is a subtype of the
// sealed `StrictClockError`, so a caller can exhaustively `switch` on
// it. None of these carry generated FFI types.

part of 'strict_clock.dart';

/// Base of every error thrown by [StrictClockContext] and its
/// resolution entry points. Sealed: `switch` over it is exhaustive.
sealed class StrictClockError implements Exception {
  const StrictClockError._();

  /// Human-readable explanation. Never contains clock readings that
  /// could be mistaken for a fallback value.
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
  /// points report as `NtsError.abiMismatch`.
  abiMismatch,

  /// The bridge threw something that is not a typed clock fault and
  /// not a decode failure: a missing symbol, a disposed entrypoint, an
  /// unstubbed mock method.
  bridge,
}

/// A native read (or the bridge carrying it) failed.
final class StrictClockSourceFault extends StrictClockError {
  /// Construct the error.
  const StrictClockSourceFault({
    required this.kind,
    required String detail,
    this.errno,
  }) : _detail = detail,
       super._();

  /// What failed.
  final SourceFaultKind kind;

  /// `errno` for [SourceFaultKind.syscallFailed]; `null` otherwise.
  final int? errno;

  final String _detail;

  @override
  String get message => 'strict clock source fault (${kind.name}): $_detail';
}

/// A reading came back strictly below an earlier one on the same
/// context and generation.
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

  /// Generation the invalidated context (or offending reading) was on.
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
