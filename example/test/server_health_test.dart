// Phase-aware classification coverage for `summarizeServer`, plus the
// `requiredBackend` assertion `probeHost` layers on top of it.
//
// Pins the `phase -> verdict` mapping (NTS-56): a probe wave that only
// fast-failed inside the local DNS resolver — on the pool cap
// (`dnsSaturation`) or on a refused worker thread (`dnsSpawnFailed`) —
// must surface as the distinct, non-drop `dnsExhausted` bucket rather
// than reading as a server-side `notReplying`.
//
// The `probeHost` group drives the real runner over a scripted bridge
// so both mismatch sites are exercised: the warm's own attribution and
// each sample's, the latter reachable because a query re-handshakes
// when the warmed cookie pool is spent or its session was evicted.
//
// The scripted bridge deals in the FFI DTOs `NtsRustLibApi` is defined
// over, the same way `lib/src/mock_api.dart` does.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:typed_data' show Uint16List;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts show NtsClient, TrustBackend;
import 'package:nts/src/ffi/api/nts.dart'
    as ffi
    show
        NtsClient,
        NtsServerSpec,
        NtsTimeSample,
        NtsWarmCookiesOutcome,
        PhaseTimings,
        TrustBackend;
import 'package:nts/src/ffi/frb_generated.dart' show NtsRustLib;
import 'package:nts_example/src/data/server_entry.dart' show NtsServerEntry;
import 'package:nts_example/src/health/probe.dart';
import 'package:nts_example/src/health/server_health.dart';
import 'package:nts_example/src/mock_api.dart';

ProbeFailure _fail(
  String type, {
  bool severe = false,
  String? phase,
  ProbeStage stage = ProbeStage.ntp,
}) => ProbeFailure(
  errorType: type,
  errorSeverity: severe,
  phase: phase,
  stage: stage,
);

ProbeFailure _timeout(String phase, {ProbeStage stage = ProbeStage.ntp}) =>
    _fail('Timeout', phase: phase, stage: stage);

ServerHealth _summarize(List<ProbeResult> results) =>
    summarizeServer(hostname: 'h.example', results: results);

void main() {
  group('summarizeServer — no successful sample', () {
    test('all dnsSaturation timeouts -> dnsExhausted, not a drop', () {
      final h = _summarize([
        _timeout('dnsSaturation'),
        _timeout('dnsSaturation'),
      ]);
      expect(h.verdict, HealthVerdict.dnsExhausted);
      expect(h.isDropCandidate, isFalse);
      expect(h.dominantErrorType, 'Timeout(dnsSaturation)');
      expect(h.reasons.single, contains('DNS resolver refused every lookup'));
      expect(h.successes, 0);
    });

    test('all dnsSpawnFailed timeouts -> dnsExhausted, not a drop', () {
      final h = _summarize([
        _timeout('dnsSpawnFailed'),
        _timeout('dnsSpawnFailed'),
      ]);
      expect(h.verdict, HealthVerdict.dnsExhausted);
      expect(h.isDropCandidate, isFalse);
      expect(h.dominantErrorType, 'Timeout(dnsSpawnFailed)');
      expect(h.successes, 0);
    });

    test('mixed resolver-refusal phases -> dnsExhausted, not a drop', () {
      // Neither phase reached the server, so the wave carries no
      // evidence about it even though the two refusals have different
      // probe-side remediations.
      final h = _summarize([
        _timeout('dnsSaturation'),
        _timeout('dnsSpawnFailed'),
      ]);
      expect(h.verdict, HealthVerdict.dnsExhausted);
      expect(h.isDropCandidate, isFalse);
    });

    test('dnsSpawnFailed mixed with a server-side phase -> drop', () {
      // A non-resolver outcome means we did get signal about the
      // server, so the resolver-refusal shortcut must not apply.
      final h = _summarize([_timeout('dnsSpawnFailed'), _timeout('ntp')]);
      expect(h.verdict, HealthVerdict.notReplying);
      expect(h.isDropCandidate, isTrue);
    });

    test('all generic Network failures -> notReplying drop', () {
      final h = _summarize([_fail('Network'), _fail('Network')]);
      expect(h.verdict, HealthVerdict.notReplying);
      expect(h.isDropCandidate, isTrue);
      expect(h.dominantErrorType, 'Network');
    });

    test(
      'all dnsTimeout timeouts -> notReplying (only saturation is local)',
      () {
        final h = _summarize([_timeout('dnsTimeout'), _timeout('dnsTimeout')]);
        expect(h.verdict, HealthVerdict.notReplying);
        expect(h.isDropCandidate, isTrue);
        expect(h.dominantErrorType, 'Timeout(dnsTimeout)');
      },
    );

    test('error-severity failure -> nonConforming drop', () {
      final h = _summarize([_fail('KeProtocol', severe: true)]);
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.isDropCandidate, isTrue);
      expect(h.dominantErrorType, 'KeProtocol');
    });

    test(
      'saturation mode but one real no-reply -> notReplying, not exhausted',
      () {
        // A single non-saturation outcome means we got *some* signal, so
        // the host is no longer purely indeterminate even though
        // saturation is the most common tag.
        final h = _summarize([
          _timeout('dnsSaturation'),
          _timeout('dnsSaturation'),
          _fail('Network'),
        ]);
        expect(h.verdict, HealthVerdict.notReplying);
        expect(h.isDropCandidate, isTrue);
        expect(h.dominantErrorType, 'Timeout(dnsSaturation)');
      },
    );

    test('empty results -> notReplying with no dominant (defensive)', () {
      final h = _summarize(const []);
      expect(h.verdict, HealthVerdict.notReplying);
      expect(h.dominantErrorType, isNull);
      expect(h.reasons, isEmpty);
    });
  });

  group('summarizeServer — KE-stage failures (warm short-circuit)', () {
    test('severe KE handshake failure -> nonConforming, dominant tag ke:', () {
      final h = _summarize([
        _fail('KeProtocol', severe: true, stage: ProbeStage.ke),
      ]);
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.isDropCandidate, isTrue);
      // The `ke:` prefix keeps a broken handshake distinguishable from a
      // flaky NTP query in the dominant-error column.
      expect(h.dominantErrorType, 'ke:KeProtocol');
    });

    test('KE completed but delivered zero cookies -> nonConforming', () {
      // probeHost synthesizes this severe KE-stage failure when the warm
      // succeeds with freshCookies < 1: the burst cannot run.
      final h = _summarize([
        _fail('NoCookies', severe: true, stage: ProbeStage.ke),
      ]);
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.dominantErrorType, 'ke:NoCookies');
    });

    test(
      'KE-stage dnsSaturation -> dnsExhausted (local artifact, not a drop)',
      () {
        final h = _summarize([_timeout('dnsSaturation', stage: ProbeStage.ke)]);
        expect(h.verdict, HealthVerdict.dnsExhausted);
        expect(h.isDropCandidate, isFalse);
        expect(h.dominantErrorType, 'ke:Timeout(dnsSaturation)');
      },
    );
  });

  group('summarizeServer — at least one successful sample', () {
    ProbeOk ok({int aeadId = 15, int stratum = 1, int offset = 0}) => ProbeOk(
      rttMicros: 1000,
      stratum: stratum,
      aeadId: aeadId,
      offsetMicros: offset,
    );

    test('baseline reply -> healthy, not a drop', () {
      final h = _summarize([ok()]);
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.isDropCandidate, isFalse);
      expect(h.reasons, isEmpty);
      expect(h.medianRttMicros, 1000);
    });

    test('a local saturation blip never downgrades a server that answered', () {
      // One OK + one dnsSaturation: the host did reply, so it stays
      // healthy with an intermittent note rather than dnsExhausted.
      final h = _summarize([ok(), _timeout('dnsSaturation')]);
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.isDropCandidate, isFalse);
      expect(h.note, contains('intermittent'));
      expect(h.successes, 1);
      expect(h.probes, 2);
    });

    test('non-baseline AEAD -> nonStandard drop', () {
      final h = _summarize([ok(aeadId: 99)]);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.isDropCandidate, isTrue);
      expect(h.reasons, contains(contains('non-baseline AEAD')));
    });

    test('unusable stratum -> nonStandard drop', () {
      final h = _summarize([ok(stratum: 0)]);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.reasons, contains(contains('unusable stratum 0')));
    });
  });

  group('summarizeServer — multi-sample aggregation', () {
    ProbeOk ok({
      int rtt = 1000,
      int stratum = 1,
      int aeadId = 15,
      int offset = 0,
    }) => ProbeOk(
      rttMicros: rtt,
      stratum: stratum,
      aeadId: aeadId,
      offsetMicros: offset,
    );

    test('clock offset beyond the threshold -> nonStandard', () {
      final h = _summarize([ok(offset: 2000000)]);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.reasons, contains(contains('clock offset')));
      expect(h.offsetMicros, 2000000);
    });

    test('unusable high stratum (>= 16) -> nonStandard', () {
      final h = _summarize([ok(stratum: 16)]);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.reasons, contains(contains('unusable stratum 16')));
    });

    test('even-length RTT list averages the two middle samples', () {
      final h = _summarize([ok(rtt: 1000), ok(rtt: 2000)]);
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.medianRttMicros, 1500);
      expect(h.successes, 2);
    });

    test('median offset is the middle sample across probes', () {
      final h = _summarize([ok(offset: -50), ok(offset: 30), ok(offset: 30)]);
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, 30);
    });

    test('stratum is the mode across successful samples', () {
      final h = _summarize([ok(stratum: 16), ok(stratum: 1), ok(stratum: 1)]);
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.stratum, 1);
    });
  });

  group('probeHost — requiredBackend assertion', () {
    // The bridge refuses a second `initMock`, so one scripted instance
    // is installed for the group and re-armed per test.
    final api = _ScriptedApi();
    setUpAll(() => NtsRustLib.initMock(api: api));
    setUp(api.reset);

    Future<ServerHealth> probe({int samples = 3}) async {
      final client = nts.NtsClient();
      try {
        return await probeHost(
          const NtsServerEntry(
            hostname: 'h.example',
            location: 'Test',
            owner: 'Test',
          ),
          port: 4460,
          timeout: const Duration(seconds: 1),
          samples: samples,
          dnsConcurrencyCap: 1,
          bridgeConcurrencyCap: 1,
          thresholds: const HealthThresholds(),
          client: client,
          requiredBackend: nts.TrustBackend.platform,
        );
      } finally {
        client.dispose();
      }
    }

    test('every handshake on the required backend -> healthy', () async {
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryBackends = [
        ffi.TrustBackend.platform,
        ffi.TrustBackend.platform,
        ffi.TrustBackend.platform,
      ];
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.successes, 3);
      expect(api.queryCalls, 3);
    });

    test('warm on the wrong backend -> nonConforming, no samples', () async {
      api.warmBackend = ffi.TrustBackend.webpkiRoots;
      final h = await probe();
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.isDropCandidate, isTrue);
      expect(h.dominantErrorType, 'ke:TrustBackendMismatch');
      // The mismatch short-circuits before the burst starts.
      expect(api.queryCalls, 0);
    });

    test('a matching warm then a mismatching sample short-circuits', () async {
      // The warm agrees, so the run reaches the burst; the second
      // query re-handshakes onto a different backend, which must
      // abandon the rest of the run rather than be averaged away by
      // the samples that did match.
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryBackends = [
        ffi.TrustBackend.platform,
        ffi.TrustBackend.webpkiRoots,
        ffi.TrustBackend.platform,
      ];
      final h = await probe();
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.isDropCandidate, isTrue);
      expect(h.dominantErrorType, 'ke:TrustBackendMismatch');
      expect(h.successes, 0);
      // Second sample tripped it: the third never dispatched.
      expect(api.queryCalls, 2);
    });

    test('null requiredBackend accepts a mixed-backend run', () async {
      // The assertion is opt-in: without it, a re-handshake onto a
      // different backend is not a fault.
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryBackends = [
        ffi.TrustBackend.webpkiRoots,
        ffi.TrustBackend.platform,
      ];
      final client = nts.NtsClient();
      try {
        final h = await probeHost(
          const NtsServerEntry(
            hostname: 'h.example',
            location: 'Test',
            owner: 'Test',
          ),
          port: 4460,
          timeout: const Duration(seconds: 1),
          samples: 2,
          dnsConcurrencyCap: 1,
          bridgeConcurrencyCap: 1,
          thresholds: const HealthThresholds(),
          client: client,
        );
        expect(h.verdict, HealthVerdict.healthy);
        expect(h.successes, 2);
      } finally {
        client.dispose();
      }
    });
  });
}

/// [MockNtsApi] with the per-client handshake attribution scripted
/// rather than randomised, so a test can pin the exact
/// warm-then-sample backend sequence `probeHost` observes.
class _ScriptedApi extends MockNtsApi {
  ffi.TrustBackend warmBackend = ffi.TrustBackend.platform;

  /// Backend for each query in dispatch order. Exhausting the list
  /// falls back to [warmBackend], matching a real client's cached
  /// session reporting the original handshake's attribution.
  List<ffi.TrustBackend> queryBackends = const [];

  int queryCalls = 0;

  /// Return to the group's defaults between tests, since the bridge
  /// only admits one `initMock` per process.
  void reset() {
    warmBackend = ffi.TrustBackend.platform;
    queryBackends = const [];
    queryCalls = 0;
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsClientWarmCookies({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) async => ffi.NtsWarmCookiesOutcome(
    freshCookies: 8,
    phaseTimings: _zeroTimings(),
    trustBackend: warmBackend,
    keWarnings: Uint16List(0),
  );

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsClientQuery({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) async {
    final backend = queryCalls < queryBackends.length
        ? queryBackends[queryCalls]
        : warmBackend;
    queryCalls++;
    return ffi.NtsTimeSample(
      utcUnixMicros: PlatformInt64Util.from(
        DateTime.now().toUtc().microsecondsSinceEpoch,
      ),
      roundTripMicros: PlatformInt64Util.from(1000),
      serverStratum: 1,
      aeadId: 15,
      freshCookies: 1,
      phaseTimings: _zeroTimings(),
      trustBackend: backend,
      recvBoottimeMicros: PlatformInt64Util.from(0),
      offsetMicros: PlatformInt64Util.from(0),
      peerDelayMicros: PlatformInt64Util.from(0),
      rootDelayMicros: PlatformInt64Util.from(0),
      rootDispersionMicros: PlatformInt64Util.from(0),
      serverPrecision: -20,
      keWarnings: Uint16List(0),
    );
  }
}

ffi.PhaseTimings _zeroTimings() => ffi.PhaseTimings(
  dnsMicros: PlatformInt64Util.from(0),
  connectMicros: PlatformInt64Util.from(0),
  tlsHandshakeMicros: PlatformInt64Util.from(0),
  keRecordIoMicros: PlatformInt64Util.from(0),
);
