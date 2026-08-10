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
    show
        NtsClient,
        NtsError,
        NtsServerSpec,
        NtsTimeSample,
        TrustBackend,
        ntsQuery,
        ntsWarmCookies;

import '../data/server_entry.dart' show NtsServerEntry;
import '../state/nts_format.dart'
    show errorTrustBackend, errorTypeName, isErrorSeverity, timeoutPhaseName;
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
///
/// [client] routes every handshake through a caller-owned
/// [NtsClient] — used when the run selected a non-default trust
/// policy — and `null` keeps the probes on the top-level functions and
/// the package's process-wide default client. [requiredBackend] asserts
/// the resolved trust backend; see [probeHost].
Future<List<ServerHealth>> probeAll(
  List<NtsServerEntry> entries, {
  required int port,
  required Duration timeout,
  required int samples,
  required int concurrency,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  required HealthThresholds thresholds,
  NtsClient? client,
  TrustBackend? requiredBackend,
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
        timeout: timeout,
        samples: samples,
        dnsConcurrencyCap: dnsConcurrencyCap,
        bridgeConcurrencyCap: bridgeConcurrencyCap,
        thresholds: thresholds,
        client: client,
        requiredBackend: requiredBackend,
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
/// alone. Otherwise each successful `ntsQuery` becomes a [ProbeOk]
/// carrying the sample's RFC 5905 clock offset θ, or a `null` offset
/// when a local clock step left θ untrustworthy (see
/// [_plausibleOffsetMicros]); an [NtsError] becomes a typed
/// [ProbeStage.ntp] [ProbeFailure]; any other throwable is bucketed as
/// a severe `Unhandled` failure.
///
/// [client] routes both stages through a caller-owned [NtsClient]
/// instead of the top-level functions' process-wide default client.
/// When [requiredBackend] is non-null every call this host makes must
/// have resolved that [TrustBackend]: the warm's outcome is checked,
/// and so is each sample's own attribution, since a query re-handshakes
/// when the warmed cookie pool is spent or its session was evicted.
/// Failures are checked too — an [NtsError] carrying a backend (see
/// `errorTrustBackend`) names the anchor set its call was configured
/// with, so a call configured wrongly that then lost the NTP leg is
/// attributed to the policy violation rather than to the timeout it
/// surfaced as.
///
/// This is a backend-*resolution* assertion, not a proof that a chain
/// was verified: the initial backend is resolved before any DNS,
/// connect, or TLS I/O, so a host that was never reached can still be
/// reported as mismatching. That is intended — the policy is about
/// which anchor set the call would have trusted. The one exception is
/// Android's [TrustBackend.platformWithHybridFallback], which is only
/// resolved once the fallback verifier has accepted a chain during
/// TLS, so a call attributed to it did verify one.
///
/// The first mismatch, whichever stage observes it, abandons the rest
/// of the run and reports a severe `TrustBackendMismatch`
/// [ProbeStage.ke] failure on its own, so the host classifies as
/// [HealthVerdict.nonConforming] and becomes a drop candidate.
Future<ServerHealth> probeHost(
  NtsServerEntry entry, {
  required int port,
  required Duration timeout,
  required int samples,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  required HealthThresholds thresholds,
  NtsClient? client,
  TrustBackend? requiredBackend,
}) async {
  final spec = NtsServerSpec(host: entry.hostname, port: port);

  // Stage 1: one NTS-KE handshake to establish the session and harvest
  // the cookie pool the burst will spend. Failures here are KE-stage.
  try {
    final warm = client == null
        ? await ntsWarmCookies(
            spec: spec,
            timeout: timeout,
            dnsConcurrencyCap: dnsConcurrencyCap,
            bridgeConcurrencyCap: bridgeConcurrencyCap,
          )
        : await client.warmCookies(
            spec: spec,
            timeout: timeout,
            dnsConcurrencyCap: dnsConcurrencyCap,
            bridgeConcurrencyCap: bridgeConcurrencyCap,
          );
    if (requiredBackend != null && warm.trustBackend != requiredBackend) {
      return _trustMismatch(entry.hostname, thresholds);
    }
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
    // Same attribution rule as the burst below: a warm that resolved a
    // backend and then failed still violated the policy, so report the
    // violation rather than the downstream symptom.
    final attributed = errorTrustBackend(err);
    if (requiredBackend != null &&
        attributed != null &&
        attributed != requiredBackend) {
      return _trustMismatch(entry.hostname, thresholds);
    }
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
  // cached session usually means these reuse the AEAD keys and spend a
  // stored cookie apiece, but an exhausted pool or an evicted session
  // makes a query re-handshake, so each sample carries its own trust
  // attribution; failures here are NTP-stage.
  final results = <ProbeResult>[];
  for (var i = 0; i < samples; i++) {
    try {
      final s = client == null
          ? await ntsQuery(
              spec: spec,
              timeout: timeout,
              dnsConcurrencyCap: dnsConcurrencyCap,
              bridgeConcurrencyCap: bridgeConcurrencyCap,
            )
          : await client.query(
              spec: spec,
              timeout: timeout,
              dnsConcurrencyCap: dnsConcurrencyCap,
              bridgeConcurrencyCap: bridgeConcurrencyCap,
            );
      if (requiredBackend != null && s.trustBackend != requiredBackend) {
        return _trustMismatch(entry.hostname, thresholds);
      }
      results.add(
        ProbeOk(
          rttMicros: s.roundTripMicros,
          stratum: s.serverStratum,
          aeadId: s.aeadId,
          offsetMicros: _plausibleOffsetMicros(s, thresholds),
        ),
      );
    } on NtsError catch (err) {
      // A failure that carries backend attribution proves its
      // handshake reached config-build time, so the assertion applies
      // to it exactly as it does to a success: a re-handshake
      // configured with the wrong anchor set that then lost the NTP
      // leg is a policy violation, not the ordinary timeout the shape
      // would otherwise be recorded as. The attribution says which
      // anchor set the call was configured to trust, so this arm also
      // catches a DNS or connect failure that never reached TLS.
      final attributed = errorTrustBackend(err);
      if (requiredBackend != null &&
          attributed != null &&
          attributed != requiredBackend) {
        return _trustMismatch(entry.hostname, thresholds);
      }
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

/// The sample's RFC 5905 offset θ, or `null` when it cannot be
/// trusted.
///
/// θ is computed from four timestamps, two of which are local
/// system-clock readings, so a clock step anywhere between T1 and T4
/// corrupts it — and unlike `ntsGetTime`, which surfaces θ as a
/// statistic, this module feeds it into a verdict that decides whether
/// a host stays in the catalog. A corrupted θ would eject a healthy
/// server, so it is screened out here.
///
/// The peer delay δ is the available witness, since it is derived from
/// the same four stamps and is a duration: a step in either direction
/// drives it out of the range a delay can occupy. A backwards step
/// subtracts from δ, a forwards step adds to it, and θ is corrupted by
/// half the step in the opposite sense either way.
///
/// A δ at or below zero cannot be a real delay and needs no tolerance,
/// so it is an unambiguous witness to a backwards step; a zero also
/// marks a pre-7.1 or hand-built sample, which carries no θ worth
/// reporting either.
///
/// The upper bound catches forward steps, but it cannot be the
/// `δ <= roundTripMicros` one `ntsGetTime` applies (see
/// `_effectiveDelayMicros`). T1 is captured before the packet is built
/// and the UDP socket bound, while `roundTripMicros` starts at the
/// send, so δ legitimately carries a pre-send interval the round trip
/// excludes — measured against the catalog it exceeds the round trip by
/// 1–9% on every healthy server, so that bound would suppress every
/// real sample.
///
/// The allowance over the round trip is additive rather than a multiple
/// of it, because the pre-send interval includes the NTPv4-host DNS
/// lookup, whose latency is unrelated to the round trip: a slow lookup
/// in front of a LAN-local server would blow any ratio-derived ceiling
/// on a perfectly healthy sample. Its size is
/// [HealthThresholds.offsetThresholdMicros], the same limit the verdict
/// uses, since a step of S inflates δ by S and corrupts θ by S/2 — so
/// every step large enough to push |θ| past the threshold on its own is
/// rejected, while a setup cost measured in milliseconds is not. The
/// bound can tighten to the strict one once the native capture points
/// are aligned.
int? _plausibleOffsetMicros(NtsTimeSample s, HealthThresholds thresholds) =>
    s.peerDelayMicros > 0 &&
        s.peerDelayMicros <=
            s.roundTripMicros + thresholds.offsetThresholdMicros
    ? s.offsetMicros
    : null;

/// Reduce a host to the single severe KE-stage `TrustBackendMismatch`
/// failure a `--require-trust-backend` violation earns, whichever
/// handshake — the warm or a later sample's — observed it.
ServerHealth _trustMismatch(String hostname, HealthThresholds thresholds) =>
    summarizeServer(
      hostname: hostname,
      results: const [
        ProbeFailure(
          errorType: 'TrustBackendMismatch',
          errorSeverity: true,
          stage: ProbeStage.ke,
        ),
      ],
      thresholds: thresholds,
    );
