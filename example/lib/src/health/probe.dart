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
/// when the sample's own peer delay (see [_plausibleOffsetMicros]) or
/// the rest of the burst (see [_corroborateOffsets]) leaves θ
/// untrustworthy; an [NtsError] becomes a typed [ProbeStage.ntp]
/// [ProbeFailure]; any other throwable is bucketed as a severe
/// `Unhandled` failure.
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
  //
  // Successes are held as raw samples until the burst finishes, because
  // whether a sample's θ is trustworthy depends on the samples around
  // it (see [_corroborateOffsets]); failures are recorded as they occur.
  // The two lists are concatenated at the end, and `summarizeServer`
  // reduces by mode and median, so the interleaving is not observable.
  final results = <ProbeResult>[];
  final ok = <NtsTimeSample>[];
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
      ok.add(s);
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
    results: [
      ...results,
      for (final (i, offset) in _corroborateOffsets(ok).indexed)
        ProbeOk(
          rttMicros: ok[i].roundTripMicros,
          stratum: ok[i].serverStratum,
          aeadId: ok[i].aeadId,
          offsetMicros: offset,
        ),
    ],
    thresholds: thresholds,
  );
}

/// Everything in the pre-send interval that is not the NTPv4-host DNS
/// lookup: building and signing the request packet, and binding and
/// connecting the UDP socket. All of it is syscall- and memcpy-scale
/// work with no I/O wait, so a single flat ceiling covers it on any
/// machine the catalog tools run on.
const _kSetupSlackMicros = 5000;

/// θ for each of [samples] in order, `null` where it cannot be trusted.
///
/// θ is computed from four timestamps, two of which are local
/// system-clock readings, so a clock step anywhere between T1 and T4
/// corrupts it — and unlike `ntsGetTime`, which surfaces θ as a
/// statistic, this module feeds it into a verdict that decides whether
/// a host stays in the catalog. A corrupted θ would eject a healthy
/// server, so it is screened out here, by two independent tests: each
/// sample's own peer delay, then the burst's agreement.
///
/// The per-sample test uses the peer delay δ, the available witness,
/// since it is derived from the same four stamps and is a duration: a
/// sufficiently large step in either direction drives it out of the
/// range a delay can occupy. A backwards step subtracts from δ, a
/// forwards step adds to it, and θ is corrupted by half the step in the
/// opposite sense either way.
///
/// A δ at or below zero cannot be a real delay and needs no tolerance,
/// so it is an unambiguous witness to an implausible exchange; a zero
/// also marks a pre-7.1 or hand-built sample, which carries no θ worth
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
/// The allowance over the round trip is therefore that interval,
/// measured rather than assumed: `phaseTimings.dnsMicros` where it is
/// the NTPv4-host lookup alone, plus [_kSetupSlackMicros] for the build
/// and the bind. Sizing it from the sample bounds the step that can slip
/// through at the setup cost itself — single-digit milliseconds, so
/// single-digit milliseconds of corruption in θ — rather than at
/// whatever the verdict threshold happens to be. It has to be additive
/// rather than a multiple of the round trip, since a slow lookup in
/// front of a LAN-local server would blow any ratio-derived ceiling on a
/// perfectly healthy sample. The bound can tighten to the strict one
/// once the native capture points are aligned.
///
/// The lookup term is only claimable on a sample that ran no handshake,
/// which is why [_rehandshaked] gates it: `dnsMicros` sums both lookups
/// a query can make, and the KE-host one precedes T1.
///
/// The burst test then requires corroboration: a surviving θ is kept
/// only if another surviving sample agrees with it to within the
/// smallest *round trip* the burst observed. Samples taken seconds apart
/// over one path cannot honestly disagree by more than the delay scale
/// that path exhibits, and a step of S displaces one sample's θ by S/2,
/// which the window admits only while S is within twice that scale. The
/// scale is taken from `roundTripMicros` rather than δ for two reasons:
/// δ carries the pre-send interval this file has just finished
/// documenting, so a slow lookup would widen the window by an amount
/// that has nothing to do with the path, and δ is computed from the
/// stepped clock itself, whereas `roundTripMicros` is a monotonic
/// measurement no step can move. That immunity is what makes the
/// residual symmetric: a backwards step deflates δ where a forward step
/// inflates it, but neither touches the window. This is what stops a
/// step small enough to pass the per-sample bound from moving a host's
/// median across the verdict threshold. A burst with fewer than two
/// surviving samples has nothing to corroborate against and is left to
/// the per-sample bound alone.
List<int?> _corroborateOffsets(List<NtsTimeSample> samples) {
  final gated = [for (final s in samples) _plausibleOffsetMicros(s)];
  final witnesses = [
    for (final (i, offset) in gated.indexed)
      if (offset != null) i,
  ];
  if (witnesses.length < 2) return gated;
  final window = witnesses.map((i) => samples[i].roundTripMicros).reduce(min);
  return [
    for (final (i, offset) in gated.indexed)
      offset != null &&
              witnesses.any(
                (j) => j != i && (offset - gated[j]!).abs() <= window,
              )
          ? offset
          : null,
  ];
}

/// Whether [s]'s query ran an NTS-KE handshake of its own, which a burst
/// sample does only when the warmed pool was exhausted or its session
/// evicted.
///
/// It matters because `phaseTimings.dnsMicros` is the *sum* of the
/// KE-host and NTPv4-host lookups, while T1 is stamped after the
/// handshake completes. On a re-handshaked sample the field therefore
/// over-counts the pre-send interval by a lookup that finished before
/// T1 and so cannot excuse any part of δ — enough, behind a slow
/// resolver, to widen the bound past a step it exists to catch. The
/// three KE-only phases are zero exactly when no handshake ran, so their
/// disjunction is the discriminator; on a re-handshaked sample the
/// NTPv4-host lookup goes unclaimed and the bound is merely stricter
/// than it could be.
bool _rehandshaked(NtsTimeSample s) =>
    s.phaseTimings.connectMicros != 0 ||
    s.phaseTimings.tlsHandshakeMicros != 0 ||
    s.phaseTimings.keRecordIoMicros != 0;

/// [s]'s θ when its own peer delay is a plausible duration for the
/// exchange that produced it, else `null`. See [_corroborateOffsets]
/// for the derivation and for the burst-level test layered on top.
int? _plausibleOffsetMicros(NtsTimeSample s) {
  final allowance = _rehandshaked(s)
      ? _kSetupSlackMicros
      : s.phaseTimings.dnsMicros + _kSetupSlackMicros;
  return s.peerDelayMicros > 0 &&
          s.peerDelayMicros <= s.roundTripMicros + allowance
      ? s.offsetMicros
      : null;
}

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
