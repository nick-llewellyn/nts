// Pure, Flutter-free health classification for NTS server probes.
//
// Consumes the outcome of one-or-more `ntsQuery` probes per host (as
// [ProbeResult]s) and produces a single [ServerHealth] verdict used by
// `bin/nts_health.dart` to rank servers and suggest catalog removals.
// Kept dependency-light (only the pure `aeadLabel` helper) so it runs
// under plain `dart run` and is trivially unit-testable without the
// FRB bridge.

import '../state/nts_format.dart' show aeadLabel;

/// Coarse health buckets. [healthy] and [dnsExhausted] are kept; every
/// other verdict is a drop candidate (see [ServerHealth.isDropCandidate]).
///
/// [dnsExhausted] is deliberately *not* a drop candidate: it means every
/// probe fast-failed inside the probe-side DNS resolver — either
/// `dnsSaturation` (the process-wide pool was full) or `dnsSpawnFailed`
/// (the OS refused a worker thread) — and the server was never
/// contacted. Both are measurement artifacts of our own resource limits,
/// not evidence the server is unhealthy, so condemning it would wrongly
/// weed a server we never actually reached. The two are grouped here
/// because the verdict only turns on "no packet was sent"; they differ in
/// remediation, which is a probe-side concern reported separately.
enum HealthVerdict {
  healthy,
  nonStandard,
  notReplying,
  nonConforming,
  dnsExhausted,
}

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

/// Which protocol stage a [ProbeFailure] originated in. Each host is
/// probed the way a client uses one: a single NTS-KE handshake
/// (`ntsWarmCookies`) to harvest a cookie pool, then a burst of NTPv4
/// queries (`ntsQuery`) spent against it. [ke] marks a failure in that
/// handshake (TLS, KE records, zero cookies); [ntp] marks a failure in
/// one of the post-warm UDP queries. Separating the two keeps a broken
/// handshake from reading as a flaky NTP server (and vice-versa) in the
/// dominant-error column.
enum ProbeStage { ke, ntp }

/// A failed probe, carrying the `errorTypeName` tag and whether it is
/// error-severity (`isErrorSeverity`) — the latter distinguishes a
/// non-conforming server from a merely-unreachable one.
///
/// [phase] holds the `timeoutPhaseName` tag for an `NtsError.timeout`
/// (`bridgeSaturation`, `dnsSaturation`, `dnsTimeout`, `connect`,
/// `tls`, `keRecordIo`, `ntp`) and is `null` for every non-timeout
/// shape. The classifier
/// uses it to surface a local DNS-pool exhaustion distinctly from a
/// server-side no-reply rather than collapsing both onto `Timeout`.
///
/// [stage] attributes the failure to the KE handshake or the NTP burst;
/// it defaults to [ProbeStage.ntp] (the post-warm queries). A
/// [ProbeStage.ke] failure is not necessarily the warm's: a
/// `--require-trust-backend` violation is attributed to the call that
/// resolved the wrong backend, and a query re-handshakes once the
/// warmed cookie pool is spent or its session was evicted, so a sample
/// can raise one too. Treat the stage as "a handshake failed", not
/// "the warm failed" — and note that a mismatch is a trust-backend
/// *resolution* mismatch, so it can be raised by a call that never
/// completed a TLS chain at all.
class ProbeFailure extends ProbeResult {
  final String errorType;
  final bool errorSeverity;
  final String? phase;
  final ProbeStage stage;
  const ProbeFailure({
    required this.errorType,
    required this.errorSeverity,
    this.phase,
    this.stage = ProbeStage.ntp,
  });
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

  /// True for anything that should be suggested for removal. Both
  /// [HealthVerdict.healthy] and [HealthVerdict.dnsExhausted] are
  /// excluded: the latter is a probe-side measurement artifact (the
  /// server was never contacted), so it carries no signal that the
  /// server should be weeded.
  bool get isDropCandidate =>
      verdict != HealthVerdict.healthy && verdict != HealthVerdict.dnsExhausted;
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
    // Phase-aware dominant tag: a timeout's phase is part of its
    // identity, so `Timeout(dnsSaturation)` is distinguishable from a
    // bare `Network` no-reply in the dominant-error column.
    final dominant = _mode(fails.map(_failureTag));
    // Every probe fast-failed inside the local DNS resolver and the
    // server was never reached — a probe-side artifact, not a server
    // fault. `dnsSpawnFailed` counts alongside `dnsSaturation`: the
    // causes differ (thread/memory ceiling vs. pool cap) and so does
    // the remediation, but both fast-fail before any packet is sent, so
    // neither carries evidence about the server. Stronger than
    // "resolver refusal was the mode": a single non-refusal outcome
    // means we got *some* signal, so we fall back to the ordinary
    // no-reply / non-conforming split below.
    const resolverRefusalPhases = {'dnsSaturation', 'dnsSpawnFailed'};
    final allResolverRefused =
        fails.isNotEmpty &&
        fails.every(
          (f) =>
              f.errorType == 'Timeout' &&
              resolverRefusalPhases.contains(f.phase),
        );
    if (allResolverRefused) {
      return ServerHealth(
        hostname: hostname,
        verdict: HealthVerdict.dnsExhausted,
        reasons: const [
          'local DNS resolver refused every lookup (pool exhausted or '
              'worker thread unavailable); probe fast-failed before the '
              'server was contacted (not a server fault)',
        ],
        probes: probes,
        successes: successes,
        dominantErrorType: dominant,
      );
    }
    final anyError = fails.any((f) => f.errorSeverity);
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

/// Phase-aware display tag for a failed probe. A timeout carries its
/// phase (`Timeout(dnsSaturation)`) so the dominant-error column and
/// the report distinguish a local resolver-cap fast-fail from a
/// server-side no-reply; every non-timeout failure renders as its bare
/// variant tag. A KE-stage failure is prefixed `ke:` (`ke:KeProtocol`,
/// `ke:Timeout(tls)`) so a broken handshake is distinguishable from a
/// flaky NTP query in the same column.
String _failureTag(ProbeFailure f) {
  final base = f.phase == null ? f.errorType : '${f.errorType}(${f.phase})';
  return f.stage == ProbeStage.ke ? 'ke:$base' : base;
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
