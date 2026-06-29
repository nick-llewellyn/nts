// Rendering coverage for `health_report.dart` (the nts_health CLI's
// output layer) plus the shared `offsetLabel` helper.
//
// Deferred from PR #189 (NTS-55), whose checklist left "unit tests for
// the new modules" unchecked. The classifier (`server_health.dart`) was
// covered by NTS-56; this pins the three report shapes the CLI emits —
// JSON, CSV, and the human-readable ranked text report — and the
// suggested-removals drop-list, independently of the decision logic.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts_example/src/health/health_report.dart';
import 'package:nts_example/src/health/server_health.dart';

ServerHealth _h(
  String host,
  HealthVerdict verdict, {
  List<String> reasons = const [],
  String? note,
  int probes = 1,
  int successes = 1,
  int? medianRttMicros,
  int? stratum,
  int? aeadId,
  int? offsetMicros,
  String? dominantErrorType,
}) => ServerHealth(
  hostname: host,
  verdict: verdict,
  reasons: reasons,
  note: note,
  probes: probes,
  successes: successes,
  medianRttMicros: medianRttMicros,
  stratum: stratum,
  aeadId: aeadId,
  offsetMicros: offsetMicros,
  dominantErrorType: dominantErrorType,
);

ServerHealth _healthy(String host, {required int rtt, int offset = 0}) => _h(
  host,
  HealthVerdict.healthy,
  probes: 3,
  successes: 3,
  medianRttMicros: rtt,
  stratum: 1,
  aeadId: 15,
  offsetMicros: offset,
);

void main() {
  group('dropList', () {
    test('only drop candidates, sorted; healthy + dnsExhausted excluded', () {
      final all = [
        _healthy('keep.example', rtt: 500),
        _h('sat.example', HealthVerdict.dnsExhausted, successes: 0, probes: 2),
        _h('zeta.example', HealthVerdict.notReplying, successes: 0),
        _h(
          'alpha.example',
          HealthVerdict.nonStandard,
          reasons: const ['non-baseline AEAD unknown(99)'],
        ),
        _h('mid.example', HealthVerdict.nonConforming, successes: 0),
      ];
      expect(dropList(all), ['alpha.example', 'mid.example', 'zeta.example']);
    });

    test('empty input -> empty drop-list', () {
      expect(dropList(const []), isEmpty);
    });
  });

  group('jsonReport', () {
    test('healthy host exposes the full stable field set', () {
      final h = _h(
        'a.example',
        HealthVerdict.healthy,
        probes: 3,
        successes: 3,
        medianRttMicros: 1500,
        stratum: 1,
        aeadId: 15,
        offsetMicros: 1200,
      );
      expect(jsonReport([h]).single, {
        'host': 'a.example',
        'verdict': 'healthy',
        'probes': 3,
        'successes': 3,
        'reasons': <String>[],
        'median_rtt_micros': 1500,
        'stratum': 1,
        'aead_id': 15,
        'aead_label': 'AES-SIV-CMAC-256(15)',
        'offset_micros': 1200,
        'error_type': null,
      });
    });

    test('error host nulls the numeric fields and the aead label', () {
      final e = _h(
        'z.example',
        HealthVerdict.notReplying,
        probes: 2,
        successes: 0,
        reasons: const ['Network'],
        dominantErrorType: 'Network',
      );
      expect(jsonReport([e]).single, {
        'host': 'z.example',
        'verdict': 'notReplying',
        'probes': 2,
        'successes': 0,
        'reasons': ['Network'],
        'median_rtt_micros': null,
        'stratum': null,
        'aead_id': null,
        'aead_label': null,
        'offset_micros': null,
        'error_type': 'Network',
      });
    });

    test('note key present only when a note is set', () {
      final without = jsonReport([_healthy('a.example', rtt: 1)]).single;
      expect(without.containsKey('note'), isFalse);
      final withNote = jsonReport([
        _h(
          'b.example',
          HealthVerdict.healthy,
          probes: 2,
          successes: 1,
          note: 'intermittent (1/2 ok)',
          medianRttMicros: 1,
          stratum: 1,
          aeadId: 15,
          offsetMicros: 0,
        ),
      ]).single;
      expect(withNote['note'], 'intermittent (1/2 ok)');
    });
  });

  group('csvReport', () {
    test('fixed header row', () {
      expect(
        csvReport(const []).trim(),
        'host,verdict,probes,successes,median_rtt_micros,stratum,'
        'aead_id,offset_micros,error_type,reasons',
      );
    });

    test('healthy + error rows render empty cells for null fields', () {
      final lines = csvReport([
        _h(
          'a.example',
          HealthVerdict.healthy,
          probes: 3,
          successes: 3,
          medianRttMicros: 1500,
          stratum: 1,
          aeadId: 15,
          offsetMicros: 1200,
        ),
        _h(
          'z.example',
          HealthVerdict.notReplying,
          probes: 2,
          successes: 0,
          reasons: const ['Network'],
          dominantErrorType: 'Network',
        ),
      ]).trimRight().split('\n');
      expect(lines[1], 'a.example,healthy,3,3,1500,1,15,1200,,');
      expect(lines[2], 'z.example,notReplying,2,0,,,,,Network,Network');
    });

    test('a comma-bearing reason is quoted; embedded quotes are doubled', () {
      final csv = csvReport([
        _h(
          'a.example',
          HealthVerdict.nonStandard,
          medianRttMicros: 1,
          stratum: 1,
          aeadId: 99,
          reasons: const ['weird, "odd" value'],
        ),
      ]);
      expect(csv, contains('"weird, ""odd"" value"'));
    });
  });

  group('renderTextReport', () {
    List<ServerHealth> mixed() => [
      _healthy('slow.example', rtt: 2000),
      _healthy('fast.example', rtt: 500),
      _h(
        'odd.example',
        HealthVerdict.nonStandard,
        reasons: const ['non-baseline AEAD unknown(99)'],
      ),
      _h(
        'dead.example',
        HealthVerdict.notReplying,
        successes: 0,
        dominantErrorType: 'Network',
      ),
      _h(
        'bad.example',
        HealthVerdict.nonConforming,
        successes: 0,
        dominantErrorType: 'KeProtocol',
      ),
      _h('sat.example', HealthVerdict.dnsExhausted, successes: 0, probes: 2),
    ];

    test('header echoes source and the probed/sample counts', () {
      final out = renderTextReport(mixed(), source: 'list.yml', samples: 3);
      expect(out, contains('source: list.yml'));
      expect(out, contains('probed: 6 host(s) \u00d7 3 sample(s)'));
    });

    test('healthy hosts are ranked by ascending median RTT', () {
      final out = renderTextReport(mixed());
      expect(out, contains('Healthy (2), ranked by median RTT:'));
      expect(
        out.indexOf('fast.example'),
        lessThan(out.indexOf('slow.example')),
      );
    });

    test('one section per bucket with the right counts', () {
      final out = renderTextReport(mixed());
      expect(out, contains('Non-standard (1):'));
      expect(out, contains('Not replying (1):'));
      expect(out, contains('Non-conforming (1):'));
      expect(
        out,
        contains('DNS-exhausted (local cap; not a server fault) (1):'),
      );
    });

    test('summary line tallies every bucket', () {
      expect(
        renderTextReport(mixed()),
        contains(
          'Summary: 2 healthy, 1 non-standard, 1 not replying, '
          '1 non-conforming, 1 dns-exhausted (6 total)',
        ),
      );
    });

    test(
      'suggested removals list the drops, excluding healthy + exhausted',
      () {
        final out = renderTextReport(mixed());
        final removals = out.substring(out.indexOf('Suggested removals'));
        expect(removals, startsWith('Suggested removals (3):'));
        for (final h in ['bad.example', 'dead.example', 'odd.example']) {
          expect(removals, contains(h));
        }
        for (final h in ['fast.example', 'slow.example', 'sat.example']) {
          expect(removals, isNot(contains(h)));
        }
      },
    );

    test('empty batch renders (none) placeholders and zeroed summary', () {
      final out = renderTextReport(const []);
      expect(out, contains('Healthy (0), ranked by median RTT:\n  (none)'));
      expect(out, contains('(0 total)'));
      expect(out, contains('Suggested removals (0):\n  (none)'));
    });
  });

  group('offsetLabel', () {
    test('sub-millisecond renders signed microseconds', () {
      expect(offsetLabel(0), '+0\u00b5s');
      expect(offsetLabel(750), '+750\u00b5s');
      expect(offsetLabel(-999), '-999\u00b5s');
    });

    test('sub-second renders signed milliseconds (one decimal)', () {
      expect(offsetLabel(1000), '+1.0ms');
      expect(offsetLabel(12345), '+12.3ms');
      expect(offsetLabel(-12345), '-12.3ms');
    });

    test('one second or more renders signed seconds (two decimals)', () {
      expect(offsetLabel(1000000), '+1.00s');
      expect(offsetLabel(-1500000), '-1.50s');
    });
  });
}
