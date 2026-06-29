// Phase-aware classification coverage for `summarizeServer`.
//
// Pins the `phase -> verdict` mapping (NTS-56): a probe wave that only
// fast-failed on the local DNS-pool cap (`dnsSaturation`) must surface
// as the distinct, non-drop `dnsExhausted` bucket rather than reading
// as a server-side `notReplying`.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts_example/src/health/server_health.dart';

ProbeFailure _fail(String type, {bool severe = false, String? phase}) =>
    ProbeFailure(errorType: type, errorSeverity: severe, phase: phase);

ProbeFailure _timeout(String phase) => _fail('Timeout', phase: phase);

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
      expect(h.reasons.single, contains('DNS resolver pool exhausted'));
      expect(h.successes, 0);
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
}
