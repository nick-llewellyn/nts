// Strict projection of an authenticated time. Part of strict_clock.dart.
//
// `NtsSyncedTime` (models.dart) anchors on `MonotonicClock.instance`
// and projects through it forever, best-effort. This type is the
// strict counterpart: it is bound to the `StrictClockContext` that
// metered the acquisition and to the reading taken as its anchor, and
// every projection re-reads that context — so a fault, a regression,
// a bridge reset or a native generation change fails the projection
// on that call instead of continuing on a timeline that may have
// stopped counting.

part of 'strict_clock.dart';

/// Authenticated UTC bound to a [StrictClockContext].
///
/// Produced by `ntsGetTimeStrict` / `NtsClient.getTimeStrict`. The
/// compensated [utcUnixMicros] is valid at [anchorMicros] on the
/// context's coordinate; [utcNow] and [elapsedSinceSync] advance it by
/// a fresh read on the same context and therefore throw a
/// [StrictClockError] whenever that read would: the context faulted,
/// regressed, saw a bridge reset, or its native generation moved.
/// There is no fallback to `MonotonicClock`, and the anchor is never
/// re-based onto a later context — resolve a new context and acquire
/// again.
///
/// Like `NtsSyncedTime`, this is a live clock, not a value: no
/// equality, no serialisation, no restore across launches.
final class StrictSyncedTime {
  /// Bind a projection to [context] at [anchor].
  ///
  /// [anchor] must be a reading from [context] (same bridge
  /// incarnation, compatible descriptor, same generation); a foreign
  /// reading throws [StrictClockSourceIncompatible],
  /// [StrictClockDescriptorIncompatible] or
  /// [StrictClockGenerationIncompatible] synchronously, without
  /// invalidating [context]. [utcUnixMicros] must be the compensated UTC valid
  /// at that reading. Intended for the wrapper layer and for test
  /// fixtures; production code receives instances from
  /// `ntsGetTimeStrict`.
  StrictSyncedTime({
    required StrictClockContext context,
    required StrictReading anchor,
    required this.utcUnixMicros,
    required this.referenceMicros,
    required this.roundTripMicros,
    required this.samplesUsed,
    required this.trustBackend,
    this.offsetMicros = 0,
    this.jitterMicros = 0,
    int? errorBoundMicros,
  }) : _context = context,
       _anchor = anchor,
       errorBoundMicros = errorBoundMicros ?? roundTripMicros ~/ 2 {
    context._checkReadingBelongs(anchor);
  }

  final StrictClockContext _context;
  final StrictReading _anchor;

  /// One-way-delay-compensated server UTC as microseconds since the
  /// Unix epoch, valid at [anchorMicros].
  final int utcUnixMicros;

  /// The winning sample's wire-level receipt stamp on the context's
  /// coordinate: `NtsTimeSample.recvBoottimeMicros` as read by the
  /// native worker under [generation]. The compensated UTC was aged
  /// from this instant to [anchorMicros]; it is exposed so a caller
  /// can audit that lag. Same-boot only, never persist.
  final int referenceMicros;

  /// Round-trip time of the winning sample, in microseconds.
  final int roundTripMicros;

  /// Burst samples that entered the lowest-delay selection. At least
  /// `1`.
  final int samplesUsed;

  /// Winning sample's clock offset θ in microseconds (RFC 5905 §8).
  final int offsetMicros;

  /// Burst sample jitter ψ in microseconds (RFC 5905 §10).
  final int jitterMicros;

  /// Worst-case error bound at the anchor instant, in microseconds.
  /// A snapshot: add oscillator drift over [elapsedSinceSync] for a
  /// current figure.
  final int errorBoundMicros;

  /// Trust-anchor backend that authenticated the winning sample.
  final TrustBackend trustBackend;

  /// Coordinate the anchor and every projection are on.
  ClockSourceDescriptor get descriptor => _anchor.descriptor;

  /// Generation the acquisition ran under. Every projection
  /// re-validates it.
  int get generation => _anchor.generation;

  /// Reading on [descriptor] at which [utcUnixMicros] is valid.
  int get anchorMicros => _anchor.micros;

  /// Whether the bound context can still project. Once `false`, every
  /// [utcNow] / [elapsedSinceSync] throws [StrictClockInvalidated].
  bool get isValid => _context.isValid;

  /// Time elapsed since the anchor on the bound context.
  ///
  /// Throws the [StrictClockError] the context's read raised; a
  /// reading below the anchor is a [StrictClockRegression], never a
  /// zero.
  Duration elapsedSinceSync() => _context.elapsedSince(_anchor);

  /// Authenticated UTC now: [utcUnixMicros] advanced by
  /// [elapsedSinceSync]. Throws on the same terms.
  DateTime utcNow() => DateTime.fromMicrosecondsSinceEpoch(
    utcUnixMicros + elapsedSinceSync().inMicroseconds,
    isUtc: true,
  );

  @override
  String toString() =>
      'StrictSyncedTime(utcUnixMicros: $utcUnixMicros, '
      'referenceMicros: $referenceMicros, anchorMicros: $anchorMicros, '
      'generation: $generation, descriptor: $descriptor, '
      'roundTripMicros: $roundTripMicros, samplesUsed: $samplesUsed, '
      'trustBackend: ${trustBackend.name}, offsetMicros: $offsetMicros, '
      'jitterMicros: $jitterMicros, errorBoundMicros: $errorBoundMicros, '
      'isValid: $isValid)';
}
