// Pure-function coverage for the formatting helpers shared between
// the on-screen log (`NtsController`) and the CLI (`bin/nts_cli.dart`).

import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' show NtsError, NtsTimeSample;
import 'package:nts_example/src/state/nts_format.dart';

void main() {
  group('formatRtt', () {
    test('sub-millisecond renders in microseconds', () {
      expect(formatRtt(750), '750µs');
    });

    test('sub-second renders in milliseconds with two decimals', () {
      expect(formatRtt(12_500), '12.50ms');
      expect(formatRtt(226_000), '226.00ms');
    });

    test('one second or more renders in seconds with two decimals', () {
      expect(formatRtt(1_000_000), '1.00s');
      expect(formatRtt(2_345_678), '2.35s');
    });
  });

  group('aeadLabel', () {
    test('known IANA ids resolve to their canonical names', () {
      expect(aeadLabel(15), 'AES-SIV-CMAC-256(15)');
      expect(aeadLabel(30), 'AES-128-GCM-SIV(30)');
    });

    test('unknown ids fall back to "unknown(id)"', () {
      expect(aeadLabel(99), 'unknown(99)');
    });
  });

  group('formatQuerySuccess', () {
    test('renders a two-line headline / continuation pair', () {
      final sample = NtsTimeSample(
        utcUnixMicros: PlatformInt64Util.from(1_777_334_400 * 1000000),
        roundTripMicros: PlatformInt64Util.from(226_000),
        serverStratum: 1,
        aeadId: 15,
        freshCookies: 2,
      );
      final out = formatQuerySuccess(sample);
      final lines = out.split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('OK '));
      expect(lines[0], contains('rtt='));
      expect(lines[0], contains('stratum=1'));
      expect(lines[0], contains('utc='));
      expect(lines[1], startsWith('    └─ '));
      expect(lines[1], contains('aead=AES-SIV-CMAC-256(15)'));
      expect(lines[1], contains('cookies=2'));
    });
  });

  group('formatWarmSuccess', () {
    test('renders OK + count', () {
      expect(formatWarmSuccess(8), 'OK  recovered 8 fresh cookie(s)');
    });
  });

  group('NtsError severity + description', () {
    test('authentication / KE / NTP / internal errors are error-severity', () {
      expect(isErrorSeverity(const NtsError.authentication('x')), isTrue);
      expect(isErrorSeverity(const NtsError.keProtocol('x')), isTrue);
      expect(isErrorSeverity(const NtsError.ntpProtocol('x')), isTrue);
      expect(isErrorSeverity(const NtsError.internal('x')), isTrue);
    });

    test('network / timeout / spec / no-cookies errors are warn-severity', () {
      expect(isErrorSeverity(const NtsError.network('x')), isFalse);
      expect(isErrorSeverity(const NtsError.timeout()), isFalse);
      expect(isErrorSeverity(const NtsError.invalidSpec('x')), isFalse);
      expect(isErrorSeverity(const NtsError.noCookies()), isFalse);
    });

    test('describe round-trips the variant payload', () {
      expect(describeError(const NtsError.network('boom')), 'Network: boom');
      expect(describeError(const NtsError.timeout()), startsWith('Timeout'));
      expect(
        describeError(const NtsError.noCookies()),
        startsWith('NoCookies'),
      );
    });
  });

  group('errorTypeName', () {
    test('returns the stable variant tag for every NtsError shape', () {
      expect(errorTypeName(const NtsError.invalidSpec('x')), 'InvalidSpec');
      expect(errorTypeName(const NtsError.network('x')), 'Network');
      expect(errorTypeName(const NtsError.keProtocol('x')), 'KeProtocol');
      expect(errorTypeName(const NtsError.ntpProtocol('x')), 'NtpProtocol');
      expect(
        errorTypeName(const NtsError.authentication('x')),
        'Authentication',
      );
      expect(errorTypeName(const NtsError.timeout()), 'Timeout');
      expect(errorTypeName(const NtsError.noCookies()), 'NoCookies');
      expect(errorTypeName(const NtsError.internal('x')), 'Internal');
    });
  });

  group('jsonQuerySuccess', () {
    test('exposes the raw NtsTimeSample fields plus aead label / utc', () {
      // utc_unix_micros chosen so the ISO rendering is exact and stable;
      // RTT 35.65ms, stratum 3, AEAD 15.
      final micros = DateTime.utc(
        2026,
        4,
        26,
        11,
        5,
        1,
        0,
        916207,
      ).microsecondsSinceEpoch;
      final sample = NtsTimeSample(
        utcUnixMicros: PlatformInt64Util.from(micros),
        roundTripMicros: PlatformInt64Util.from(35650),
        serverStratum: 3,
        aeadId: 15,
        freshCookies: 2,
      );

      expect(jsonQuerySuccess(sample), {
        'utc_unix_micros': micros,
        'utc': '2026-04-26T11:05:01.916207Z',
        'rtt_micros': 35650,
        'stratum': 3,
        'aead_id': 15,
        'aead_label': 'AES-SIV-CMAC-256(15)',
        'cookies': 2,
      });
    });

    test('survives jsonEncode round-trip without losing fields', () {
      final sample = NtsTimeSample(
        utcUnixMicros: PlatformInt64Util.from(1_777_334_400 * 1000000),
        roundTripMicros: PlatformInt64Util.from(750),
        serverStratum: 1,
        aeadId: 30,
        freshCookies: 8,
      );

      final encoded = jsonEncode(jsonQuerySuccess(sample));
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['stratum'], 1);
      expect(decoded['aead_label'], 'AES-128-GCM-SIV(30)');
      expect(decoded['cookies'], 8);
      expect(decoded['rtt_micros'], 750);
    });
  });

  group('jsonWarmSuccess', () {
    test('emits a single-key cookie count', () {
      expect(jsonWarmSuccess(8), {'cookies': 8});
    });
  });

  group('jsonError', () {
    test('warn-severity errors carry severity=warn + variant tag', () {
      expect(jsonError(const NtsError.network('boom')), {
        'error_type': 'Network',
        'message': 'Network: boom',
        'severity': 'warn',
      });
      expect(jsonError(const NtsError.timeout()), {
        'error_type': 'Timeout',
        'message': startsWith('Timeout'),
        'severity': 'warn',
      });
      expect(jsonError(const NtsError.noCookies()), {
        'error_type': 'NoCookies',
        'message': startsWith('NoCookies'),
        'severity': 'warn',
      });
    });

    test('error-severity errors carry severity=error', () {
      expect(
        jsonError(const NtsError.authentication('bad mac'))['severity'],
        'error',
      );
      expect(
        jsonError(const NtsError.keProtocol('bad alpn'))['severity'],
        'error',
      );
      expect(
        jsonError(const NtsError.ntpProtocol('bad pkt'))['severity'],
        'error',
      );
      expect(jsonError(const NtsError.internal('panic'))['severity'], 'error');
    });
  });
}
