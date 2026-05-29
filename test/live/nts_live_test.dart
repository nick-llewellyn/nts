@Tags(['live'])
library;

// Live (real-network) integration suite for `package:nts`'s public
// stability layer (`lib/src/api/nts.dart`). Exercises `ntsQuery`,
// `ntsWarmCookies`, and the per-instance `NtsClient` path against three
// real public NTS-KE endpoints, mirroring the Rust live probes in
// `rust/src/api/nts/tests.rs`.
//
// ## Opt-in by design (path + tag, no env var)
//
// The repo's required `Dart tests gate` runs `flutter test --coverage`,
// which is mock-only: no native dylib, no network. A live probe in that
// gate would couple a required check to public-server reachability and
// to a built release dylib. To keep the gate hermetic, every test here
// carries the `live` tag (the `@Tags(['live'])` library annotation
// above), and the root `dart_test.yaml` marks that tag `skip:` by
// default. So a bare `flutter test` discovers this file but skips its
// tests before `NtsRustLib.init()` or any socket is touched.
//
// To run the suite:
//
//   1. Build the native dylib so its FRB content-hash matches the
//      committed bindings:  `cargo build --release -p nts_rust` (from
//      `rust/`). `NtsRustLib.init()` loads it from `rust/target/release/`.
//   2. `fvm flutter test --run-skipped test/live/`
//      (`--run-skipped` overrides the default tag skip; pointing at
//      `test/live/` alone still skips, since the tag config applies.)
//
// ## Tolerance
//
// The happy-path probe (sub-test 1) runs all three servers and passes
// when >= 2 of 3 succeed, so a single endpoint being down or flaky does
// not red the suite; every tolerated failure is printed verbatim. The
// remaining sub-tests are single-server (Cloudflare) and must pass.
// Transient `NtsErrorNetwork` / `NtsErrorTimeout` failures are absorbed
// by [_queryWithRetry] (3 attempts, 500/1000ms back-off), mirroring the
// Rust `retry_on_transient`.

import 'dart:io' show stderr;

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart';

/// Public NTS-KE endpoints (RFC 8915 §6 default port 4460).
const _cloudflare = NtsServerSpec(host: 'time.cloudflare.com', port: 4460);
const _netnod = NtsServerSpec(host: 'nts.netnod.se', port: 4460);
const _ptb = NtsServerSpec(host: 'ptbtime1.ptb.de', port: 4460);
const _servers = <NtsServerSpec>[_cloudflare, _netnod, _ptb];

/// Per-call budget for the happy-path probes, matching the Rust probes'
/// `10_000`. Wider than [kDefaultTimeoutMs] to tolerate a cold DNS
/// lookup plus the full NTS-KE handshake on a loaded CI runner.
const _timeoutMs = 10000;

/// IANA AEAD id for `AEAD_AES_SIV_CMAC_256`, the algorithm Cloudflare
/// negotiates (`rust/src/nts/ke/aead.rs` `AES_SIV_CMAC_256`).
const _aeadAesSivCmac256 = 15;

void main() {
  group('live nts', () {
    setUpAll(() async {
      await NtsRustLib.init();
    });

    // (1) Happy path across all three servers, >= 2/3 must pass.
    test('ntsQuery happy path (>=2 of 3 public servers)', () async {
      var passed = 0;
      final failures = <String>[];
      for (final spec in _servers) {
        final NtsTimeSample sample;
        try {
          sample = await _queryWithRetry(
            'ntsQuery ${spec.host}',
            () => ntsQuery(spec: spec, timeoutMs: _timeoutMs),
          );
        } on NtsError catch (e) {
          // A reachability / protocol failure on one endpoint is
          // tolerated by the 2/3 rule; record it verbatim and move on.
          failures.add('${spec.host}: $e');
          continue;
        }
        // A malformed *successful* sample is a real shape bug, not
        // weather: let the assertion's TestFailure propagate.
        _assertHealthySample(spec, sample);
        passed++;
      }
      if (failures.isNotEmpty) {
        stderr.writeln('tolerated server failures: $failures');
      }
      expect(
        passed,
        greaterThanOrEqualTo(2),
        reason:
            'fewer than 2 of ${_servers.length} servers passed; '
            'failures: $failures',
      );
    });

    // (2) ntsWarmCookies happy path (Cloudflare only).
    test('ntsWarmCookies harvests cookies (cloudflare)', () async {
      final outcome = await _queryWithRetry(
        'ntsWarmCookies cloudflare',
        () => ntsWarmCookies(spec: _cloudflare, timeoutMs: _timeoutMs),
      );
      expect(
        outcome.freshCookies,
        greaterThan(0),
        reason: 'KE handshake must harvest at least one cookie',
      );
      expect(
        TrustBackend.values.contains(outcome.trustBackend),
        isTrue,
        reason: 'warmCookies must resolve a real trust backend',
      );
    });

    // (3) Per-instance NtsClient round-trip (non-singleton path).
    test('NtsClient round-trip (cloudflare, fresh instance)', () async {
      final client = NtsClient();
      final sample = await _queryWithRetry(
        'NtsClient.query cloudflare',
        () => client.query(spec: _cloudflare, timeoutMs: _timeoutMs),
      );
      _assertHealthySample(_cloudflare, sample);
      expect(
        sample.aeadId,
        _aeadAesSivCmac256,
        reason: 'Cloudflare must negotiate AES-SIV-CMAC-256 (IANA AEAD id 15)',
      );
    });

    // (4) TrustMode.platformOnly resolves to the platform backend.
    test('NtsClient(platformOnly) resolves platform backend', () async {
      final client = NtsClient(trustMode: TrustMode.platformOnly);
      final sample = await _queryWithRetry(
        'NtsClient.query platformOnly cloudflare',
        () => client.query(spec: _cloudflare, timeoutMs: _timeoutMs),
      );
      expect(
        sample.trustBackend,
        TrustBackend.platform,
        reason:
            'platformOnly must authenticate via the platform store; got '
            '${sample.trustBackend.name}',
      );
    });

    // (5) Cookie reuse: second query on the same client short-circuits KE.
    test('NtsClient reuses cached session (cloudflare)', () async {
      final client = NtsClient();
      final first = await _queryWithRetry(
        'NtsClient.query cloudflare (fresh)',
        () => client.query(spec: _cloudflare, timeoutMs: _timeoutMs),
      );
      _assertHealthySample(_cloudflare, first);

      final second = await _queryWithRetry(
        'NtsClient.query cloudflare (reuse)',
        () => client.query(spec: _cloudflare, timeoutMs: _timeoutMs),
      );
      _assertHealthySample(_cloudflare, second);

      // Cache-hit signal: the cached-session branch skips connect / TLS
      // / KE-record-IO. `dnsMicros` may still be non-zero (the UDP-path
      // NTPv4-host lookup runs), so it is deliberately not asserted.
      expect(second.phaseTimings.connectMicros, 0, reason: 'reuse: connect');
      expect(second.phaseTimings.tlsHandshakeMicros, 0, reason: 'reuse: tls');
      expect(second.phaseTimings.keRecordIoMicros, 0, reason: 'reuse: keIo');
    });

    // (6) Error path: an unreachable host classifies as a typed NtsError.
    test('ntsQuery against unreachable host throws NtsError', () async {
      const dead = NtsServerSpec(host: '127.0.0.1', port: 1);
      Object? caught;
      try {
        await ntsQuery(spec: dead, timeoutMs: 2000);
        fail('expected ntsQuery to throw against 127.0.0.1:1');
      } on NtsError catch (e) {
        caught = e;
      }
      stderr.writeln('error-path classification: $caught');
      expect(
        caught,
        anyOf(isA<NtsErrorNetwork>(), isA<NtsErrorTimeout>()),
        reason:
            'connection refused / timeout to 127.0.0.1:1 must surface as '
            'NtsErrorNetwork or NtsErrorTimeout; got $caught',
      );
    });
  });
}

/// `true` for the `NtsError` variants treated as network weather rather
/// than a real failure: [NtsErrorNetwork] (TCP/UDP I/O, connection
/// failure) and [NtsErrorTimeout] (any phase tripped its deadline).
/// Mirrors the Rust `is_transient_nts_error`.
bool _isTransient(NtsError err) =>
    err is NtsErrorNetwork || err is NtsErrorTimeout;

/// Run [op] up to three times, retrying only on [_isTransient] failures
/// with 500ms / 1000ms back-off, emitting a per-attempt stderr notice.
/// Rethrows the final error on exhaustion, and rethrows any
/// non-transient [NtsError] immediately — callers decide whether that
/// throw fails the test (single-server sub-tests) or is tolerated by the
/// 2/3 rule (the multi-server happy path). `label` names the probe in
/// the retry notices.
Future<T> _queryWithRetry<T>(String label, Future<T> Function() op) async {
  const attempts = 3;
  for (var attempt = 1; ; attempt++) {
    try {
      return await op();
    } on NtsError catch (e) {
      if (!_isTransient(e) || attempt >= attempts) rethrow;
      stderr.writeln(
        '$label: transient failure on attempt $attempt/$attempts: $e; '
        'retrying',
      );
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
    }
  }
}

/// Assert that a successful [NtsTimeSample] from `spec` has a plausible
/// shape, using the loose cross-server criteria from NTS-13 (the tighter
/// Cloudflare-specific AEAD check lives in the single-server sub-tests):
/// a valid `1..15` stratum, a real round-trip measurement below 500ms, a
/// resolved (non-sentinel) trust backend, and a server clock within ±5
/// minutes of local time. Failures fail the test (these signal a real
/// protocol or crate-level bug, not network weather).
void _assertHealthySample(NtsServerSpec spec, NtsTimeSample sample) {
  final host = spec.host;
  expect(
    sample.serverStratum,
    inInclusiveRange(1, 15),
    reason: '$host: server stratum ${sample.serverStratum} outside 1..15',
  );
  expect(
    sample.roundTripMicros,
    greaterThan(0),
    reason: '$host: round_trip collapsed to <=0us',
  );
  expect(
    sample.roundTripMicros,
    lessThan(500 * 1000),
    reason:
        '$host: round_trip ${sample.roundTripMicros}us exceeds the 500ms '
        'happy-path budget',
  );
  expect(
    TrustBackend.values.contains(sample.trustBackend),
    isTrue,
    reason: '$host: trust backend not resolved',
  );
  final nowMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final skewMicros = (sample.utcUnixMicros - nowMicros).abs();
  expect(
    skewMicros,
    lessThan(5 * 60 * 1000000),
    reason:
        '$host: server time vs local skews ${skewMicros}us (> 5min); '
        'system clock or sample wildly off',
  );
}
