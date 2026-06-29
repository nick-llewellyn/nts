// Pure, Flutter-free health classification for NTS server probes.
//
// Consumes the outcome of one-or-more `ntsQuery` probes per host (as
// [ProbeResult]s) and produces a single [ServerHealth] verdict used by
// `bin/nts_health.dart` to rank servers and suggest catalog removals.
// Kept dependency-light (only the pure `aeadLabel` helper) so it runs
// under plain `dart run` and is trivially unit-testable without the
// FRB bridge.

import '../state/nts_format.dart' show aeadLabel;

/// Coarse health buckets. Anything other than [healthy] is a drop
/// candidate (see [ServerHealth.isDropCandidate]).
enum HealthVerdict { healthy, nonStandard, notReplying, nonConforming }

/// Tunable classification limits. Defaults: ±1s clock offset, the two
/// RFC 8915 AEADs (15 = AES-SIV-CMAC-256 baseline, 30 = AES-128-GCM-SIV),
/// and a usable stratum window of 1..15 (0 and ≥16 are unusable).
class HealthThresholds {
  final int offsetThresholdMicros;
  final Set<int> baselineAeadIds;
  final int minStratum;
  final int maxStratum;
  const HealthThresholds({
    this.offsetThresholdMicros = 1000000,
    this.baselineAeadIds = const {15, 30},
    this.minStratum = 1,
    this.maxStratum = 15,
  });
}

/// One probe's outcome: either a successful sample or a failure.
sealed class ProbeResult {
  const ProbeResult();
}

/// A successful `ntsQuery` sample reduced to the classification inputs.
/// [offsetMicros] is the signed estimate of (server clock − local
/// clock) at reply receipt.
class ProbeOk extends ProbeResult {
  final int rttMicros;
  final int stratum;
  final int aeadId;
  final int offsetMicros;
  const ProbeOk({
    required this.rttMicros,
    required this.stratum,
    required this.aeadId,
    required this.offsetMicros,
  });
}

/// A failed probe, carrying the `errorTypeName` tag and whether it is
/// error-severity (`isErrorSeverity`) — the latter distinguishes a
/// non-conforming server from a merely-unreachable one.
class ProbeFailure extends ProbeResult {
  final String errorType;
  final bool errorSeverity;
  const ProbeFailure({required this.errorType, required this.errorSeverity});
}

/// Aggregated verdict for one host across all its probes.
class ServerHealth {
  final String hostname;
  final HealthVerdict verdict;
  final List<String> reasons;
  final String? note;
  final int probes;
  final int successes;
  final int? medianRttMicros;
  final int? stratum;
  final int? aeadId;
  final int? offsetMicros;
  final String? dominantErrorType;
  const ServerHealth({
    required this.hostname,
    required this.verdict,
    required this.reasons,
    required this.probes,
    required this.successes,
    this.note,
    this.medianRttMicros,
    this.stratum,
    this.aeadId,
    this.offsetMicros,
    this.dominantErrorType,
  });

  /// True for anything that should be suggested for removal.
  bool get isDropCandidate => verdict != HealthVerdict.healthy;
}

/// Reduce a host's [results] to a single [ServerHealth].
ServerHealth summarizeServer({
  required String hostname,
  required List<ProbeResult> results,
  HealthThresholds thresholds = const HealthThresholds(),
}) {
  final oks = results.whereType<ProbeOk>().toList();
  final fails = results.whereType<ProbeFailure>().toList();
  final probes = results.length;
  final successes = oks.length;

  if (oks.isEmpty) {
    final anyError = fails.any((f) => f.errorSeverity);
    final dominant = _mode(fails.map((f) => f.errorType));
    return ServerHealth(
      hostname: hostname,
      verdict: anyError
          ? HealthVerdict.nonConforming
          : HealthVerdict.notReplying,
      reasons: [?dominant],
      probes: probes,
      successes: successes,
      dominantErrorType: dominant,
    );
  }

  final rtts = oks.map((o) => o.rttMicros).toList()..sort();
  final offsets = oks.map((o) => o.offsetMicros).toList()..sort();
  final stratum = _mode(oks.map((o) => o.stratum))!;
  final aeadId = _mode(oks.map((o) => o.aeadId))!;
  final offset = _median(offsets);

  final reasons = <String>[];
  if (!thresholds.baselineAeadIds.contains(aeadId)) {
    reasons.add('non-baseline AEAD ${aeadLabel(aeadId)}');
  }
  if (stratum < thresholds.minStratum || stratum > thresholds.maxStratum) {
    reasons.add('unusable stratum $stratum');
  }
  if (offset.abs() > thresholds.offsetThresholdMicros) {
    reasons.add('clock offset ${offsetLabel(offset)}');
  }

  return ServerHealth(
    hostname: hostname,
    verdict: reasons.isEmpty
        ? HealthVerdict.healthy
        : HealthVerdict.nonStandard,
    reasons: reasons,
    note: successes < probes ? 'intermittent ($successes/$probes ok)' : null,
    probes: probes,
    successes: successes,
    medianRttMicros: _median(rtts),
    stratum: stratum,
    aeadId: aeadId,
    offsetMicros: offset,
  );
}

/// Median of a pre-sorted list; even-length lists average the two
/// middle values (rounded). Returns 0 for an empty list.
int _median(List<int> sorted) {
  final n = sorted.length;
  if (n == 0) return 0;
  final mid = n ~/ 2;
  return n.isOdd ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

/// Most frequently occurring element, or null for an empty input.
/// First-seen wins ties (insertion order through the iterable).
T? _mode<T>(Iterable<T> xs) {
  final counts = <T, int>{};
  T? best;
  var bestN = -1;
  for (final x in xs) {
    final c = counts[x] = (counts[x] ?? 0) + 1;
    if (c > bestN) {
      bestN = c;
      best = x;
    }
  }
  return best;
}

/// Signed, unit-scaled rendering of a clock offset in microseconds
/// (e.g. `+12.3ms`, `-1.50s`). Shared by the classifier's reason text
/// and the report renderer.
String offsetLabel(int micros) {
  final sign = micros < 0 ? '-' : '+';
  final a = micros.abs();
  if (a < 1000) return '$sign$a\u00b5s';
  if (a < 1000000) return '$sign${(a / 1000).toStringAsFixed(1)}ms';
  return '$sign${(a / 1000000).toStringAsFixed(2)}s';
}
