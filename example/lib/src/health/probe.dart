// Shared live-probe runner for the example app's catalog tools.
//
// Extracted from `bin/nts_health.dart` so both the catalog health
// auditor and the reliable-server manifest generator
// (`bin/nts_manifest.dart`) drive the *same* probing and classification
// pipeline. Each host is probed the way a real client uses one: a single
// NTS-KE handshake (`ntsWarmCookies`) to establish the session and
// harvest a cookie pool, then a burst of NTPv4 queries (`ntsQuery`)
// spent against that pool rather than a fresh handshake per sample. This
// module is pure orchestration over the FRB bridge: the only side effect
// is an optional progress callback, so each CLI owns its own stderr
// formatting.

import 'dart:math' show min;

import 'package:nts/nts.dart'
    show NtsError, NtsServerSpec, ntsQuery, ntsWarmCookies;

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

/// Probe one host the way a client would: warm a single NTS-KE
/// handshake, then fire a burst of [samples] NTPv4 queries against the
/// delivered cookie pool, and reduce the whole run to one [ServerHealth].
///
/// The warm (`ntsWarmCookies`) is measured on its own so a broken
/// handshake is attributed as a [ProbeStage.ke] failure — distinct from
/// a flaky NTP query. A KE that fails, or completes but delivers zero
/// cookies, short-circuits the burst and classifies from the handshake
/// alone. Otherwise each successful `ntsQuery` becomes a [ProbeOk] (with
/// a signed server-minus-local clock offset estimated at reply receipt);
/// an [NtsError] becomes a typed [ProbeStage.ntp] [ProbeFailure]; any
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

  // Stage 1: one NTS-KE handshake to establish the session and harvest
  // the cookie pool the burst will spend. Failures here are KE-stage.
  try {
    final warm = await ntsWarmCookies(
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    );
    if (warm.freshCookies < 1) {
      // KE completed but issued no cookies: the burst cannot run as a
      // client would, so treat it as a severe (non-conforming) fault.
      return summarizeServer(
        hostname: entry.hostname,
        results: const [
          ProbeFailure(
            errorType: 'NoCookies',
            errorSeverity: true,
            stage: ProbeStage.ke,
          ),
        ],
        thresholds: thresholds,
      );
    }
  } on NtsError catch (err) {
    return summarizeServer(
      hostname: entry.hostname,
      results: [
        ProbeFailure(
          errorType: errorTypeName(err),
          errorSeverity: isErrorSeverity(err),
          phase: timeoutPhaseName(err),
          stage: ProbeStage.ke,
        ),
      ],
      thresholds: thresholds,
    );
  } catch (_) {
    return summarizeServer(
      hostname: entry.hostname,
      results: const [
        ProbeFailure(
          errorType: 'Unhandled',
          errorSeverity: true,
          stage: ProbeStage.ke,
        ),
      ],
      thresholds: thresholds,
    );
  }

  // Stage 2: burst [samples] NTPv4 queries against the warmed pool. The
  // cached session means these reuse the AEAD keys and spend a stored
  // cookie apiece rather than re-handshaking; failures here are NTP-stage.
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
