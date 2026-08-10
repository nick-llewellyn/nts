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
// so every mismatch site is exercised: the warm's own attribution and
// each sample's, the latter reachable because a query re-handshakes
// when the warmed cookie pool is spent or its session was evicted, and
// the attribution carried by a *failed* call, which is what a
// wrong-backend re-handshake that then loses the NTP leg looks like.
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
        NtsError,
        NtsServerSpec,
        NtsTimeSample,
        NtsWarmCookiesOutcome,
        PhaseTimings,
        TimeoutPhase,
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
      int? offset = 0,
    }) => ProbeOk(
      rttMicros: rtt,
      stratum: stratum,
      aeadId: aeadId,
      offsetMicros: offset,
    );

    test('samples with no usable θ are dropped from the median', () {
      // A suppressed sample must not be read as a zero offset: doing so
      // would pull the median of a genuinely skewed host back toward
      // zero and hide the skew.
      final h = _summarize([
        ok(offset: null),
        ok(offset: 2000000),
        ok(offset: 2000000),
      ]);
      expect(h.offsetMicros, 2000000);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.note, isNull);
    });

    test('every θ suppressed leaves no offset and no offset reason', () {
      final h = _summarize([ok(offset: null), ok(offset: null)]);
      expect(h.offsetMicros, isNull);
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.reasons, isEmpty);
      expect(h.note, contains('clock offset unavailable'));
    });

    test('an intermittent run with θ suppressed reports both notes', () {
      final h = _summarize([
        ok(offset: null),
        const ProbeFailure(errorType: 'Timeout', errorSeverity: false),
      ]);
      expect(h.note, contains('intermittent (1/2 ok)'));
      expect(h.note, contains('clock offset unavailable'));
    });

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

    Future<ServerHealth> probe({
      int samples = 3,
      HealthThresholds thresholds = const HealthThresholds(),
    }) async {
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
          thresholds: thresholds,
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

    test('the sample offset reported is the wire θ, not rtt/2', () async {
      // The scripted `utcUnixMicros` is read from the local clock as
      // the mock builds the sample, so the pre-θ derivation
      // (server time + half the 1 ms round trip − a `DateTime.now()`
      // taken once the await has returned) evaluates to
      // `500µs − handoff`. That is bounded above by +500µs and
      // unbounded below, so only a value well *above* +500µs is
      // unreachable by it — a negative fixture would still pass
      // against the old code on a slow enough handoff. θ is set to
      // +250 ms, comfortably inside the ±1 s verdict threshold.
      api.offsetMicros = 250000;
      api.queryBackends = [
        ffi.TrustBackend.platform,
        ffi.TrustBackend.platform,
        ffi.TrustBackend.platform,
      ];
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, 250000);
    });

    test('an implausible peer delay suppresses θ instead of judging on '
        'it', () async {
      // A non-positive peer delay cannot be a real duration, so it
      // witnesses an implausible exchange, which leaves θ untrustworthy.
      // The scripted θ is far outside the ±1s threshold, so propagating
      // it would eject a server whose own clock was never observed to be
      // wrong.
      api.peerDelayMicros = -400;
      api.offsetMicros = 30000000;
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, isNull);
      expect(h.note, contains('clock offset unavailable'));
    });

    test('a peer delay modestly above the round trip is not treated as '
        'a step', () {
      // T1 is captured before the UDP bind while `roundTripMicros`
      // starts at the send, so δ legitimately exceeds the round trip on
      // healthy servers (1–9% across the bundled catalog). Suppressing
      // on that would discard every real sample.
      api.peerDelayMicros = 1090;
      api.offsetMicros = 1200;
      return probe().then((h) {
        expect(h.verdict, HealthVerdict.healthy);
        expect(h.offsetMicros, 1200);
        expect(h.note, isNull);
      });
    });

    test('a peer delay far above the round trip suppresses θ', () async {
      // A forward local step adds to δ instead of subtracting, so the
      // lower bound alone would pass it through while θ is corrupted by
      // half the step in the opposite direction. The scripted δ is 3 s
      // against a 1 ms round trip, well past the pre-send interval the
      // gate tolerates.
      api.peerDelayMicros = 3000000;
      api.offsetMicros = -1500000;
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, isNull);
      expect(h.note, contains('clock offset unavailable'));
    });

    test('θ survives a peer delay exactly at the allowance', () async {
      // The bound is `roundTripMicros + dnsMicros + 5 ms`: 1 ms + 0 +
      // 5 ms against this fixture. It is inclusive, so the boundary
      // value is the largest excess the gate still reads as setup cost.
      api.peerDelayMicros = 6000;
      api.offsetMicros = 1200;
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, 1200);
      expect(h.note, isNull);
    });

    test('θ is suppressed one microsecond past the allowance', () async {
      // Pins the cutoff from the other side, so widening or narrowing
      // the allowance cannot pass silently.
      api.peerDelayMicros = 6001;
      api.offsetMicros = 1200;
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, isNull);
      expect(h.note, contains('clock offset unavailable'));
    });

    test('the allowance tracks the sample\'s own DNS cost', () async {
      // The allowance is measured from the sample rather than taken
      // from a constant or from the verdict threshold, so a lookup that
      // actually cost 20 ms widens the bound by exactly that much. The
      // same δ that was suppressed one test above now sits well inside
      // it, and the new boundary is 20 ms further out.
      api.dnsMicros = 20000;
      api.peerDelayMicros = 6001;
      api.offsetMicros = 1200;
      final h = await probe();
      expect(h.offsetMicros, 1200);
      expect(h.note, isNull);

      api.reset();
      api.dnsMicros = 20000;
      api.peerDelayMicros = 26001;
      api.offsetMicros = 1200;
      final past = await probe();
      expect(past.offsetMicros, isNull);
      expect(past.note, contains('clock offset unavailable'));
    });

    test('a sample that re-handshaked cannot claim its DNS cost', () async {
      // `dnsMicros` sums the KE-host and NTPv4-host lookups, and the
      // KE-host one completes before T1 is stamped, so on a
      // re-handshaked sample it over-counts the pre-send interval. The
      // same 20 ms lookup that widened the bound one test above buys
      // nothing here: a δ inside the widened bound but outside the flat
      // 5 ms one is rejected. Behind a slow resolver the difference is
      // the whole gate.
      api.dnsMicros = 20000;
      api.keRecordIoMicros = 1;
      api.peerDelayMicros = 6001;
      api.offsetMicros = 1200;
      final h = await probe();
      expect(h.offsetMicros, isNull);
      expect(h.note, contains('clock offset unavailable'));
    });

    test('the corroboration window ignores a sample\'s DNS cost', () async {
      // The window is the smallest `roundTripMicros`, not the smallest
      // δ. A 400 ms lookup inflates every δ well past the offsets'
      // spread, so a δ-derived window would have admitted the outlier
      // at +400 ms as a corroborating witness of its neighbours. The
      // round trip is 1 ms and unmoved by the lookup, so the outlier is
      // still dropped and the agreeing pair still carries the median.
      api.dnsMicros = 400000;
      api.peerDelayMicros = 400500;
      api.offsetScript = [1200, 1200, 400000];
      final h = await probe();
      expect(h.offsetMicros, 1200);
      expect(h.successes, 3);
      expect(h.note, isNull);
    });

    test('a slow sample can still corroborate a fast one', () async {
      // The window is half the *pair's* summed round trips, not the
      // burst's smallest. A reply queued mostly one way on a 100 ms
      // path can legitimately read 50 ms off a 1 ms sample, and a
      // burst-wide minimum would call that disagreement and suppress
      // both. That is the dangerous direction: with no surviving θ the
      // host is judged without the clock check, so this 2 s skew would
      // have been reported as healthy.
      api.roundTripScript = [1000, 100000];
      api.offsetScript = [2000000, 2050000];
      final h = await probe(samples: 2);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.reasons, contains(contains('clock offset')));
      expect(h.offsetMicros, 2025000);
      expect(h.note, isNull);
    });

    test('the pairwise window is inclusive at half the summed round '
        'trips', () async {
      // 1 ms and 100 ms round trips admit exactly 50.5 ms of honest
      // disagreement.
      api.roundTripScript = [1000, 100000];
      api.offsetScript = [0, 50500];
      final h = await probe(samples: 2);
      expect(h.offsetMicros, 25250);
      expect(h.note, isNull);

      // One microsecond past it, neither sample has a witness, which
      // pins the window from the other side.
      api.reset();
      api.roundTripScript = [1000, 100000];
      api.offsetScript = [0, 50501];
      final past = await probe(samples: 2);
      expect(past.offsetMicros, isNull);
      expect(past.note, contains('clock offset unavailable'));
    });

    test('a backwards step that leaves δ positive fails corroboration', () {
      // The per-sample bound only catches a backwards step large enough
      // to drive δ non-positive; a smaller one passes it with θ
      // displaced by half the step. The corroboration window is
      // measured on the monotonic round trip, which no step moves in
      // either direction, so the displaced sample is dropped exactly as
      // a forward step's would be.
      api.peerDelayMicros = 300;
      api.offsetScript = [1200, 1200, -400000];
      return probe().then((h) {
        expect(h.offsetMicros, 1200);
        expect(h.successes, 3);
        expect(h.note, isNull);
      });
    });

    test('a θ no other sample corroborates is suppressed', () async {
      // A step too small to push δ past the per-sample bound still
      // displaces that sample's θ, and the displacement is visible as
      // disagreement with the rest of the burst. Two samples agree at
      // +1200 µs; the third is 400 ms out with a δ the first screen
      // accepts, so only the outlier is dropped and the median comes
      // from the pair that corroborate each other.
      api.offsetScript = [1200, 1200, 400000];
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, 1200);
      expect(h.successes, 3);
      expect(h.note, isNull);
    });

    test('a burst where no two samples agree suppresses every θ', () async {
      // With every sample disagreeing with every other by more than
      // half their summed round trips, there is no corroborated reading
      // to judge on, so the host is reported without an offset rather
      // than on an arbitrary median of three inconsistent values.
      api.offsetScript = [0, 400000, 800000];
      final h = await probe();
      expect(h.verdict, HealthVerdict.healthy);
      expect(h.offsetMicros, isNull);
      expect(h.note, contains('clock offset unavailable'));
    });

    test('a lone surviving sample is judged on the per-sample bound '
        'alone', () async {
      // A one-sample burst has nothing to corroborate against.
      // Requiring agreement would suppress every θ on `--samples 1`, so
      // the burst screen stands down rather than rejecting by default.
      api.offsetMicros = 30000000;
      final h = await probe(samples: 1);
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.offsetMicros, 30000000);
    });

    test('a plausible θ beyond the threshold still flags the host', () async {
      // The converse of the suppression case: the gate must not swallow
      // a genuine skew reported by a sample with a sound δ.
      api.offsetMicros = 30000000;
      final h = await probe();
      expect(h.verdict, HealthVerdict.nonStandard);
      expect(h.reasons, contains(contains('clock offset')));
      expect(h.offsetMicros, 30000000);
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

    test('a mismatching sample that then fails is a mismatch', () async {
      // The re-handshake authenticated against the wrong anchor set
      // and only then lost the NTP leg. The attribution rides on the
      // error, so the run must report the policy violation rather than
      // the timeout it surfaced as — which alone would classify the
      // host as `notReplying`.
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryErrors = [
        null,
        const ffi.NtsError.timeout(
          phase: ffi.TimeoutPhase.ntp,
          trustBackend: ffi.TrustBackend.webpkiRoots,
        ),
      ];
      final h = await probe();
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.isDropCandidate, isTrue);
      expect(h.dominantErrorType, 'ke:TrustBackendMismatch');
      expect(api.queryCalls, 2);
    });

    test('a warm that fails on the wrong backend is a mismatch', () async {
      api.warmError = const ffi.NtsError.noCookies(
        trustBackend: ffi.TrustBackend.webpkiRoots,
      );
      final h = await probe();
      expect(h.verdict, HealthVerdict.nonConforming);
      expect(h.dominantErrorType, 'ke:TrustBackendMismatch');
      expect(api.queryCalls, 0);
    });

    test('an unattributed failure stays an ordinary failure', () async {
      // `trustBackend: null` means the failure fired before any
      // backend was resolved, so it carries no evidence either way and
      // must not be reported as a policy violation.
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryErrors = [
        const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.connect),
        const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.connect),
        const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.connect),
      ];
      final h = await probe();
      expect(h.verdict, HealthVerdict.notReplying);
      expect(h.dominantErrorType, 'Timeout(connect)');
      // No short-circuit: every sample dispatched.
      expect(api.queryCalls, 3);
    });

    test('a failure on the required backend stays an ordinary failure', () {
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryErrors = [
        const ffi.NtsError.timeout(
          phase: ffi.TimeoutPhase.ntp,
          trustBackend: ffi.TrustBackend.platform,
        ),
      ];
      return probe(samples: 1).then((h) {
        expect(h.verdict, HealthVerdict.notReplying);
        expect(h.dominantErrorType, 'Timeout(ntp)');
      });
    });

    test('the assertion holds on the default-client path too', () async {
      // Every other case in this group supplies an `NtsClient`, but
      // `probeHost` also accepts `client: null` and routes through the
      // top-level functions — the path the catalog tools take whenever
      // `--trust-mode` was left at its default. Both mismatch sites
      // are separate call sites on that path, so both are driven here.
      Future<ServerHealth> singletonProbe({int samples = 1}) => probeHost(
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
        requiredBackend: nts.TrustBackend.platform,
      );

      api.warmBackend = ffi.TrustBackend.webpkiRoots;
      final badWarm = await singletonProbe();
      expect(badWarm.verdict, HealthVerdict.nonConforming);
      expect(badWarm.dominantErrorType, 'ke:TrustBackendMismatch');
      expect(api.queryCalls, 0);

      api.reset();
      api.warmBackend = ffi.TrustBackend.platform;
      api.queryBackends = [ffi.TrustBackend.webpkiRoots];
      final badSample = await singletonProbe();
      expect(badSample.verdict, HealthVerdict.nonConforming);
      expect(badSample.dominantErrorType, 'ke:TrustBackendMismatch');
      expect(api.queryCalls, 1);

      api.reset();
      final good = await singletonProbe();
      expect(good.verdict, HealthVerdict.healthy);
      expect(good.successes, 1);
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

  /// Thrown instead of returning an outcome, so a test can script a
  /// warm that resolved a backend and then failed.
  ffi.NtsError? warmError;

  /// Backend for each query in dispatch order. Exhausting the list
  /// falls back to [warmBackend], matching a real client's cached
  /// session reporting the original handshake's attribution.
  List<ffi.TrustBackend> queryBackends = const [];

  /// Error to throw for each query in dispatch order, `null` for a
  /// success. A shorter list leaves the remaining queries succeeding.
  List<ffi.NtsError?> queryErrors = const [];

  /// θ reported by every scripted sample. Distinct from the round trip
  /// so a test can tell the propagated offset apart from anything
  /// derived locally from `utcUnixMicros` and `roundTripMicros`.
  int offsetMicros = 0;

  /// θ for each query in dispatch order, overriding [offsetMicros] for
  /// as many samples as it has entries. Lets a test drive the
  /// burst-corroboration screen, which is the only thing in the
  /// pipeline that reads one sample's θ against another's.
  List<int> offsetScript = const [];

  /// Peer delay δ reported by every scripted sample. The default is a
  /// plausible positive duration below the scripted round trip; tests
  /// drive θ's clock-step gate by making it non-positive or by pushing
  /// it far past that round trip.
  int peerDelayMicros = 800;

  /// Round trip for each query in dispatch order, overriding
  /// [roundTripMicros] for as many samples as it has entries. Lets a
  /// test drive a burst whose samples took materially different paths,
  /// which is what the pairwise corroboration window is sized for.
  List<int> roundTripScript = const [];

  /// Round trip reported by every scripted sample not covered by
  /// [roundTripScript].
  int roundTripMicros = 1000;

  /// `phaseTimings.dnsMicros` reported by every scripted sample. Zero
  /// by default, which is the cache-hit case; a test raises it to widen
  /// the per-sample plausibility bound by a measured lookup cost.
  int dnsMicros = 0;

  /// `phaseTimings.keRecordIoMicros` reported by every scripted sample.
  /// Zero by default; a non-zero value marks the sample as having run a
  /// handshake of its own, which is what the prober keys on to decide
  /// whether [dnsMicros] is attributable to the pre-send interval.
  int keRecordIoMicros = 0;

  int queryCalls = 0;

  /// Return to the group's defaults between tests, since the bridge
  /// only admits one `initMock` per process.
  void reset() {
    warmBackend = ffi.TrustBackend.platform;
    warmError = null;
    queryBackends = const [];
    queryErrors = const [];
    offsetMicros = 0;
    offsetScript = const [];
    peerDelayMicros = 800;
    roundTripScript = const [];
    roundTripMicros = 1000;
    dnsMicros = 0;
    keRecordIoMicros = 0;
    queryCalls = 0;
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsClientWarmCookies({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) => _warm();

  /// Top-level counterpart, so a `client: null` probe reads the same
  /// script as a per-client one. Both dispatch paths matter: the
  /// catalog tools take the singleton path whenever the run left
  /// `--trust-mode` at its default.
  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsWarmCookies({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) => _warm();

  Future<ffi.NtsWarmCookiesOutcome> _warm() async {
    final err = warmError;
    if (err != null) throw err;
    return ffi.NtsWarmCookiesOutcome(
      freshCookies: 8,
      phaseTimings: _zeroTimings(),
      trustBackend: warmBackend,
      keWarnings: Uint16List(0),
    );
  }

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsClientQuery({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) => _query();

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsQuery({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) => _query();

  Future<ffi.NtsTimeSample> _query() async {
    final backend = queryCalls < queryBackends.length
        ? queryBackends[queryCalls]
        : warmBackend;
    final err = queryCalls < queryErrors.length
        ? queryErrors[queryCalls]
        : null;
    final offset = queryCalls < offsetScript.length
        ? offsetScript[queryCalls]
        : offsetMicros;
    final rtt = queryCalls < roundTripScript.length
        ? roundTripScript[queryCalls]
        : roundTripMicros;
    queryCalls++;
    if (err != null) throw err;
    return ffi.NtsTimeSample(
      utcUnixMicros: PlatformInt64Util.from(
        DateTime.now().toUtc().microsecondsSinceEpoch,
      ),
      roundTripMicros: PlatformInt64Util.from(rtt),
      serverStratum: 1,
      aeadId: 15,
      freshCookies: 1,
      phaseTimings: _timings(dnsMicros, keRecordIoMicros: keRecordIoMicros),
      trustBackend: backend,
      recvBoottimeMicros: PlatformInt64Util.from(0),
      offsetMicros: PlatformInt64Util.from(offset),
      peerDelayMicros: PlatformInt64Util.from(peerDelayMicros),
      rootDelayMicros: PlatformInt64Util.from(0),
      rootDispersionMicros: PlatformInt64Util.from(0),
      serverPrecision: -20,
      keWarnings: Uint16List(0),
    );
  }
}

ffi.PhaseTimings _zeroTimings() => _timings(0);

ffi.PhaseTimings _timings(int dnsMicros, {int keRecordIoMicros = 0}) =>
    ffi.PhaseTimings(
      dnsMicros: PlatformInt64Util.from(dnsMicros),
      connectMicros: PlatformInt64Util.from(0),
      tlsHandshakeMicros: PlatformInt64Util.from(0),
      keRecordIoMicros: PlatformInt64Util.from(keRecordIoMicros),
    );
