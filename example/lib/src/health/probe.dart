// Shared live-probe runner for the example app's catalog tools.
//
// Extracted from `bin/nts_health.dart` so both the catalog health
// auditor and the reliable-server manifest generator
// (`bin/nts_manifest.dart`) drive the *same* probing and classification
// pipeline rather than duplicating the `ntsQuery` -> `summarizeServer`
// loop. This module is pure orchestration over the FRB bridge: the only
// side effect is an optional progress callback, so each CLI owns its own
// stderr formatting.

import 'dart:math' show min;

import 'package:nts/nts.dart' show NtsError, NtsServerSpec, ntsQuery;

import '../data/server_entry.dart' show NtsServerEntry;
import '../state/nts_format.dart'
    show errorTypeName, isErrorSeverity, timeoutPhaseName;
import 'server_health.dart';

/// Invoked after each host finishes, carrying the running [done]/[total]
/// counts and the host's [health]. Lets a caller stream progress without
/// this module taking ownership of stdout/stderr.
typedef ProbeProgress = void Function(int done, int total, ServerHealth health);

/// Probe every host in [entries] with bounded [concurrency] fan-out and
/// classify each into a [ServerHealth]. Results are returned in
/// completion order (not input order); callers that need a stable
/// ordering should sort by hostname.
///
/// [onProgress] is called once per completed host so a long run can show
/// liveness; pass `null` for a silent run.
Future<List<ServerHealth>> probeAll(
  List<NtsServerEntry> entries, {
  required int port,
  required int timeoutMs,
  required int samples,
  required int concurrency,
  required int dnsConcurrencyCap,
  required HealthThresholds thresholds,
  ProbeProgress? onProgress,
}) async {
  final pending = List<NtsServerEntry>.of(entries);
  final out = <ServerHealth>[];
  final total = entries.length;
  var done = 0;

  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final entry = pending.removeLast();
      final health = await probeHost(
        entry,
        port: port,
        timeoutMs: timeoutMs,
        samples: samples,
        dnsConcurrencyCap: dnsConcurrencyCap,
        thresholds: thresholds,
      );
      out.add(health);
      done++;
      onProgress?.call(done, total, health);
    }
  }

  await Future.wait([
    for (var i = 0; i < min(concurrency, total); i++) worker(),
  ]);
  return out;
}

/// Run [samples] sequential probes against one host and reduce them to a
/// single [ServerHealth] verdict. A successful `ntsQuery` becomes a
/// [ProbeOk] (with a signed server-minus-local clock offset estimated at
/// reply receipt); an [NtsError] becomes a typed [ProbeFailure]; any
/// other throwable is bucketed as a severe `Unhandled` failure.
Future<ServerHealth> probeHost(
  NtsServerEntry entry, {
  required int port,
  required int timeoutMs,
  required int samples,
  required int dnsConcurrencyCap,
  required HealthThresholds thresholds,
}) async {
  final spec = NtsServerSpec(host: entry.hostname, port: port);
  final results = <ProbeResult>[];
  for (var i = 0; i < samples; i++) {
    try {
      final s = await ntsQuery(
        spec: spec,
        timeoutMs: timeoutMs,
        dnsConcurrencyCap: dnsConcurrencyCap,
      );
      final localMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
      final serverEstimate = s.utcUnixMicros + s.roundTripMicros ~/ 2;
      results.add(
        ProbeOk(
          rttMicros: s.roundTripMicros,
          stratum: s.serverStratum,
          aeadId: s.aeadId,
          offsetMicros: serverEstimate - localMicros,
        ),
      );
    } on NtsError catch (err) {
      results.add(
        ProbeFailure(
          errorType: errorTypeName(err),
          errorSeverity: isErrorSeverity(err),
          phase: timeoutPhaseName(err),
        ),
      );
    } catch (_) {
      results.add(
        const ProbeFailure(errorType: 'Unhandled', errorSeverity: true),
      );
    }
  }
  return summarizeServer(
    hostname: entry.hostname,
    results: results,
    thresholds: thresholds,
  );
}
