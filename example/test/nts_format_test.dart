// Pure-function coverage for the formatting helpers shared between
// the on-screen log (`NtsController`) and the CLI (`bin/nts_cli.dart`).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart'
    show
        NtsError,
        NtsSyncedTime,
        NtsTimeSample,
        NtsWarmCookiesOutcome,
        PhaseTimings,
        TimeoutPhase,
        TrustBackend,
        TrustMode;
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

  group('formatTrustBackend', () {
    test('platform → short label', () {
      expect(formatTrustBackend(TrustBackend.platform), 'platform');
    });
    test('platformWithHybridFallback → short label', () {
      // `webpki-fallback` (not the former `platform+hybrid-fallback`):
      // the prior label was ambiguous about which root chain actually
      // authenticated. See the formatTrustBackend dartdoc for the
      // rename rationale (nts-t3p).
      expect(
        formatTrustBackend(TrustBackend.platformWithHybridFallback),
        'webpki-fallback',
      );
    });
    test('webpkiRoots → short label', () {
      expect(formatTrustBackend(TrustBackend.webpkiRoots), 'webpki-roots');
    });
  });

  group('formatTrustMode', () {
    test('platformWithFallback → short label', () {
      expect(
        formatTrustMode(TrustMode.platformWithFallback),
        'platform-with-fallback',
      );
    });
    test('platformOnly → short label', () {
      expect(formatTrustMode(TrustMode.platformOnly), 'platform-only');
    });
    test('bundledOnly → short label', () {
      expect(formatTrustMode(TrustMode.bundledOnly), 'bundled-only');
    });
  });

  group('formatQuerySuccess', () {
    test('renders a two-line headline / continuation pair with trust', () {
      final sample = NtsTimeSample(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 226_000,
        serverStratum: 1,
        aeadId: 15,
        freshCookies: 2,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platformWithHybridFallback,
        recvBoottimeMicros: 0,
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
      // Trust backend goes on the continuation row alongside aead /
      // cookies so the headline stays scannable.
      expect(lines[1], contains('trust=webpki-fallback'));
    });
  });

  group('formatWarmSuccess', () {
    test('renders OK + count + trust backend', () {
      final outcome = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
      );
      expect(
        formatWarmSuccess(outcome),
        'OK  recovered 8 fresh cookie(s)  trust=platform',
      );
    });
  });

  group('formatGetTimeSuccess', () {
    test('renders headline / continuation with samples, bound, trust', () {
      final synced = NtsSyncedTime(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 35_650,
        samplesUsed: 3,
        trustBackend: TrustBackend.platform,
      );
      final out = formatGetTimeSuccess(synced);
      final lines = out.split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('OK '));
      expect(lines[0], contains('rtt='));
      expect(lines[0], contains('samples=3'));
      // `utc=` renders `utcNow` (the monotonic projection), so pin
      // the prefix rather than the exact instant.
      expect(lines[0], contains('utc='));
      expect(lines[1], startsWith('    └─ '));
      // Worst-case one-way-delay bound is RTT/2 through formatRtt.
      expect(lines[1], contains('error≤±17.82ms (RTT/2)'));
      expect(lines[1], contains('trust=platform'));
    });
  });

  group('NtsError severity + description', () {
    test('authentication / KE / NTP / trust-backend / internal errors are '
        'error-severity', () {
      expect(
        isErrorSeverity(const NtsError.authentication(message: 'x')),
        isTrue,
      );
      expect(isErrorSeverity(const NtsError.keProtocol(message: 'x')), isTrue);
      expect(isErrorSeverity(const NtsError.ntpProtocol(message: 'x')), isTrue);
      // TrustBackendUnavailable is a deliberate caller-side
      // configuration choice (`PlatformOnly`) the runtime cannot
      // honour; classified as error so an operator notices the
      // misconfiguration rather than treating it as a transient
      // network blip.
      expect(
        isErrorSeverity(const NtsError.trustBackendUnavailable(message: 'x')),
        isTrue,
      );
      expect(isErrorSeverity(const NtsError.internal(message: 'x')), isTrue);
    });

    test('network / timeout / spec / no-cookies errors are warn-severity', () {
      expect(isErrorSeverity(const NtsError.network(message: 'x')), isFalse);
      expect(
        isErrorSeverity(const NtsError.timeout(phase: TimeoutPhase.ntp)),
        isFalse,
      );
      expect(
        isErrorSeverity(const NtsError.invalidSpec(message: 'x')),
        isFalse,
      );
      expect(isErrorSeverity(const NtsError.noCookies()), isFalse);
    });

    test('describe round-trips the variant payload', () {
      expect(
        describeError(const NtsError.network(message: 'boom')),
        'Network: boom',
      );
      expect(
        describeError(const NtsError.timeout(phase: TimeoutPhase.dnsTimeout)),
        startsWith('Timeout'),
      );
      expect(
        describeError(const NtsError.noCookies()),
        startsWith('NoCookies'),
      );
      expect(
        describeError(
          const NtsError.trustBackendUnavailable(
            message: 'platform CA bundle missing',
          ),
        ),
        'TrustBackendUnavailable: platform CA bundle missing',
      );
    });
  });

  group('errorTypeName', () {
    test('returns the stable variant tag for every NtsError shape', () {
      expect(
        errorTypeName(const NtsError.invalidSpec(message: 'x')),
        'InvalidSpec',
      );
      expect(errorTypeName(const NtsError.network(message: 'x')), 'Network');
      expect(
        errorTypeName(const NtsError.keProtocol(message: 'x')),
        'KeProtocol',
      );
      expect(
        errorTypeName(const NtsError.ntpProtocol(message: 'x')),
        'NtpProtocol',
      );
      expect(
        errorTypeName(const NtsError.authentication(message: 'x')),
        'Authentication',
      );
      expect(
        errorTypeName(const NtsError.timeout(phase: TimeoutPhase.ntp)),
        'Timeout',
      );
      expect(errorTypeName(const NtsError.noCookies()), 'NoCookies');
      expect(
        errorTypeName(const NtsError.trustBackendUnavailable(message: 'x')),
        'TrustBackendUnavailable',
      );
      expect(errorTypeName(const NtsError.internal(message: 'x')), 'Internal');
    });
  });

  group('timeoutPhaseName', () {
    test('returns the phase name for every Timeout phase', () {
      for (final phase in TimeoutPhase.values) {
        expect(timeoutPhaseName(NtsError.timeout(phase: phase)), phase.name);
      }
    });

    test('returns null for every non-Timeout shape', () {
      for (final err in <NtsError>[
        const NtsError.network(message: 'x'),
        const NtsError.noCookies(),
        const NtsError.invalidSpec(message: 'x'),
        const NtsError.authentication(message: 'x'),
        const NtsError.keProtocol(message: 'x'),
        const NtsError.ntpProtocol(message: 'x'),
        const NtsError.trustBackendUnavailable(message: 'x'),
        const NtsError.internal(message: 'x'),
      ]) {
        expect(timeoutPhaseName(err), isNull);
      }
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
        utcUnixMicros: micros,
        roundTripMicros: 35650,
        serverStratum: 3,
        aeadId: 15,
        freshCookies: 2,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
        recvBoottimeMicros: 0,
      );

      expect(jsonQuerySuccess(sample), {
        'utc_unix_micros': micros,
        'utc': '2026-04-26T11:05:01.916207Z',
        'rtt_micros': 35650,
        'stratum': 3,
        'aead_id': 15,
        'aead_label': 'AES-SIV-CMAC-256(15)',
        'cookies': 2,
        'trust_backend': 'platform',
      });
    });

    test('survives jsonEncode round-trip without losing fields', () {
      final sample = NtsTimeSample(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 750,
        serverStratum: 1,
        aeadId: 30,
        freshCookies: 8,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
        recvBoottimeMicros: 0,
      );

      final encoded = jsonEncode(jsonQuerySuccess(sample));
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['stratum'], 1);
      expect(decoded['aead_label'], 'AES-128-GCM-SIV(30)');
      expect(decoded['cookies'], 8);
      expect(decoded['rtt_micros'], 750);
      expect(decoded['trust_backend'], 'platform');
    });
  });

  group('jsonWarmSuccess', () {
    test('emits the cookie count plus trust-backend variant tag', () {
      final outcome = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platformWithHybridFallback,
      );
      expect(jsonWarmSuccess(outcome), {
        'cookies': 8,
        'trust_backend': 'platformWithHybridFallback',
      });
    });
  });

  group('jsonError', () {
    test('warn-severity errors carry severity=warn + variant tag', () {
      expect(jsonError(const NtsError.network(message: 'boom')), {
        'error_type': 'Network',
        'message': 'Network: boom',
        'severity': 'warn',
      });
      expect(jsonError(const NtsError.noCookies()), {
        'error_type': 'NoCookies',
        'message': 'NoCookies (server completed KE but issued zero cookies)',
        'severity': 'warn',
      });
    });

    test('Timeout failures expose the phase as a structured field', () {
      // Pinning `phase` exactly (rather than `startsWith('Timeout')`
      // on `message`) is the whole point of carrying the phase tag
      // through to JSON: machine-readable consumers must be able to
      // switch on the attribution without re-parsing the human
      // message. The two probes below cover both a non-default phase
      // (dnsTimeout — chosen because it's a frequent operator-action
      // signal in the field) and the post-bind variant (ntp) so a
      // future edit that hard-codes one phase is caught.
      expect(
        jsonError(const NtsError.timeout(phase: TimeoutPhase.dnsTimeout)),
        {
          'error_type': 'Timeout',
          'message': 'Timeout (deadline expired in phase dnsTimeout)',
          'severity': 'warn',
          'phase': 'dnsTimeout',
        },
      );
      expect(jsonError(const NtsError.timeout(phase: TimeoutPhase.ntp)), {
        'error_type': 'Timeout',
        'message': 'Timeout (deadline expired in phase ntp)',
        'severity': 'warn',
        'phase': 'ntp',
      });
    });

    test('non-Timeout failures do not carry a phase key', () {
      // Guards against an accidental copy-paste that would surface
      // `phase: null` (or a stale phase from a previous error) on a
      // non-Timeout shape. Strict containsPair / isNot ensures the
      // key is *absent*, not just falsy.
      for (final err in <NtsError>[
        const NtsError.network(message: 'x'),
        const NtsError.noCookies(),
        const NtsError.invalidSpec(message: 'x'),
        const NtsError.authentication(message: 'x'),
        const NtsError.keProtocol(message: 'x'),
        const NtsError.ntpProtocol(message: 'x'),
        const NtsError.internal(message: 'x'),
      ]) {
        expect(jsonError(err), isNot(contains('phase')));
      }
    });

    test('error-severity errors carry severity=error', () {
      expect(
        jsonError(
          const NtsError.authentication(message: 'bad mac'),
        )['severity'],
        'error',
      );
      expect(
        jsonError(const NtsError.keProtocol(message: 'bad alpn'))['severity'],
        'error',
      );
      expect(
        jsonError(const NtsError.ntpProtocol(message: 'bad pkt'))['severity'],
        'error',
      );
      expect(
        jsonError(const NtsError.internal(message: 'panic'))['severity'],
        'error',
      );
    });
  });
}

PhaseTimings _zeroPhaseTimings() => const PhaseTimings(
  dnsMicros: 0,
  connectMicros: 0,
  tlsHandshakeMicros: 0,
  keRecordIoMicros: 0,
);
