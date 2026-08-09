// Pure-function coverage for the formatting helpers shared between
// the on-screen log (`NtsController`) and the CLI (`bin/nts_cli.dart`).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart'
    show
        NtsClient,
        NtsDnsPoolStats,
        NtsError,
        NtsErrorAbiMismatch,
        NtsErrorAuthentication,
        NtsErrorInternal,
        NtsErrorInvalidSpec,
        NtsErrorKeProtocol,
        NtsErrorNetwork,
        NtsErrorNoCookies,
        NtsErrorNtpProtocol,
        NtsErrorTimeout,
        NtsErrorTrustBackendUnavailable,
        NtsRustLib,
        NtsSyncedTime,
        NtsTimeSample,
        NtsWarmCookiesOutcome,
        PhaseTimings,
        TimeoutPhase,
        TrustBackend,
        TrustMode;
import 'package:nts_example/src/mock_api.dart';
import 'package:nts_example/src/state/nts_format.dart';

void main() {
  setUpAll(() {
    // `formatGetTimeSuccess` fixtures construct NtsSyncedTime, whose
    // constructor captures a monotonic anchor from
    // MonotonicClock.instance — a StateError without bridge init.
    NtsRustLib.initMock(api: MockNtsApi());
  });

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

  group('parseTrustMode', () {
    test('round-trips every formatTrustMode label', () {
      for (final mode in TrustMode.values) {
        expect(parseTrustMode(formatTrustMode(mode)), mode);
      }
    });

    test('kTrustModeFlagValues covers exactly the four modes', () {
      expect(
        kTrustModeFlagValues.map(parseTrustMode).toList(),
        TrustMode.values,
      );
    });

    test('unrecognised values return null', () {
      expect(parseTrustMode('platformOnly'), isNull);
      expect(parseTrustMode(''), isNull);
    });
  });

  group('parseTrustBackend', () {
    test('kTrustBackendFlagValues covers exactly the four backends', () {
      expect(
        kTrustBackendFlagValues.map(parseTrustBackend).toList(),
        TrustBackend.values,
      );
    });

    test('accepts the enum name in kebab form, not the display label', () {
      // formatTrustBackend renders this variant as `webpki-fallback`,
      // which names the anchor set that won rather than the mode, so it
      // is deliberately NOT accepted as a flag value.
      expect(
        parseTrustBackend('platform-with-hybrid-fallback'),
        TrustBackend.platformWithHybridFallback,
      );
      expect(parseTrustBackend('webpki-fallback'), isNull);
    });

    test('unrecognised values return null', () {
      expect(parseTrustBackend('webpkiRoots'), isNull);
      expect(parseTrustBackend(''), isNull);
    });
  });

  group('trustPolicyPairingError', () {
    // The helper duplicates the package's own pair validation so the
    // CLIs can reject a bad pairing before `initBridge`, which the
    // constructor runs after. Duplication means drift, so every case
    // below asserts the helper's verdict *and* the constructor's on
    // the same pairing rather than trusting the helper alone.
    for (final mode in TrustMode.values) {
      for (final roots in const [
        null,
        <int>[],
        <int>[1, 2, 3],
      ]) {
        final label = '$mode + ${roots == null ? 'null' : '${roots.length}B'}';
        test('agrees with the NtsClient constructor for $label', () {
          final helperError = trustPolicyPairingError(
            trustMode: mode,
            customRoots: roots,
          );
          NtsClient? client;
          Object? constructorError;
          try {
            client = NtsClient(trustMode: mode, customRoots: roots);
          } catch (e) {
            constructorError = e;
          } finally {
            client?.dispose();
          }
          expect(
            helperError == null,
            constructorError == null,
            reason: 'helper=$helperError constructor=$constructorError',
          );
        });
      }
    }

    test('rejects roots supplied against a non-custom mode', () {
      for (final mode in TrustMode.values.where((m) => m != TrustMode.custom)) {
        expect(
          trustPolicyPairingError(trustMode: mode, customRoots: const [1]),
          contains('--custom-roots can only be set'),
          reason: '$mode',
        );
      }
    });

    test('rejects custom mode with absent or empty roots', () {
      for (final roots in const [null, <int>[]]) {
        expect(
          trustPolicyPairingError(
            trustMode: TrustMode.custom,
            customRoots: roots,
          ),
          contains('requires a non-empty --custom-roots'),
        );
      }
    });
  });

  group('wipeCustomRoots', () {
    test('zeroes a mutable buffer in place, so aliases see the wipe', () {
      final roots = Uint8List.fromList([1, 2, 3, 4]);
      final alias = roots;
      wipeCustomRoots(roots);
      expect(roots, everyElement(0));
      expect(alias, everyElement(0));
      expect(roots, hasLength(4));
    });

    test('tolerates null and an unmodifiable list', () {
      expect(() => wipeCustomRoots(null), returnsNormally);
      expect(() => wipeCustomRoots(const [1, 2, 3]), returnsNormally);
    });
  });

  group('formatTrustMismatch', () {
    test('renders both backends through the success-line vocabulary', () {
      expect(
        formatTrustMismatch(
          TrustBackend.platform,
          TrustBackend.platformWithHybridFallback,
        ),
        'FAIL  trust backend mismatch: '
        'required=platform  actual=webpki-fallback',
      );
    });

    test('covers every backend on both sides', () {
      for (final requiredBackend in TrustBackend.values) {
        for (final actualBackend in TrustBackend.values) {
          expect(
            formatTrustMismatch(requiredBackend, actualBackend),
            'FAIL  trust backend mismatch: '
            'required=${formatTrustBackend(requiredBackend)}  '
            'actual=${formatTrustBackend(actualBackend)}',
          );
        }
      }
    });
  });

  group('jsonTrustMismatch', () {
    test('carries raw enum names, not the display labels', () {
      expect(
        jsonTrustMismatch(
          TrustBackend.webpkiRoots,
          TrustBackend.platformWithHybridFallback,
        ),
        {
          'error_type': 'TrustBackendMismatch',
          'message':
              'FAIL  trust backend mismatch: '
              'required=webpki-roots  actual=webpki-fallback',
          'severity': 'error',
          'required_trust_backend': 'webpkiRoots',
          'trust_backend': 'platformWithHybridFallback',
        },
      );
    });

    test('error_type does not collide with any NtsError tag', () {
      final variantTags = {for (final err in _allNtsErrors) errorTypeName(err)};
      // Not a sealed-type variant: the CLI's own synthetic tag for a
      // throwable that is not an NtsError (`_Ctx.unhandled` in
      // bin/nts_cli.dart), so it has no switch arm to derive from.
      const syntheticTags = {'Unhandled'};
      // Kept in a separate set deliberately. Folding the synthetic tag
      // in with the variant tags would let a variant that returned
      // 'Unhandled' deduplicate silently, so the collision this test is
      // named for would pass unnoticed.
      expect(variantTags.intersection(syntheticTags), isEmpty);
      final tag =
          jsonTrustMismatch(
                TrustBackend.custom,
                TrustBackend.platform,
              )['error_type']
              as String;
      expect(variantTags, isNot(contains(tag)));
      expect(syntheticTags, isNot(contains(tag)));
    });

    test('is JSON-encodable for every backend pair', () {
      for (final requiredBackend in TrustBackend.values) {
        for (final actualBackend in TrustBackend.values) {
          final decoded =
              jsonDecode(
                    jsonEncode(
                      jsonTrustMismatch(requiredBackend, actualBackend),
                    ),
                  )
                  as Map<String, Object?>;
          expect(decoded['required_trust_backend'], requiredBackend.name);
          expect(decoded['trust_backend'], actualBackend.name);
        }
      }
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
      // No codes on the wire: the segment is omitted rather than
      // rendered empty, since every real server sends zero today.
      expect(lines[1], isNot(contains('ke-warnings')));
    });

    test('appends ke-warnings to the continuation when codes present', () {
      final sample = NtsTimeSample(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 226_000,
        serverStratum: 1,
        aeadId: 15,
        freshCookies: 2,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
        keWarnings: const [1, 4097],
      );
      final lines = formatQuerySuccess(sample).split('\n');
      expect(lines, hasLength(2));
      // Trailing position keeps the established columns stable for
      // anything grepping the continuation row.
      expect(lines[1], endsWith('ke-warnings=[1,4097]'));
      expect(lines[0], isNot(contains('ke-warnings')));
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

    test('appends ke-warnings when the handshake carried codes', () {
      final outcome = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
        keWarnings: const [7],
      );
      expect(
        formatWarmSuccess(outcome),
        'OK  recovered 8 fresh cookie(s)  trust=platform  ke-warnings=[7]',
      );
    });
  });

  group('keWarningsSegment', () {
    test('empty list renders nothing at all', () {
      expect(keWarningsSegment(const []), '');
    });
    test('single code renders a bracketed one-element list', () {
      expect(keWarningsSegment(const [1]), '  ke-warnings=[1]');
    });
    test('multiple codes are comma-joined without spaces', () {
      // No spaces inside the brackets so the segment stays a single
      // whitespace-delimited token for awk/cut on the log line.
      expect(keWarningsSegment(const [1, 2, 3]), '  ke-warnings=[1,2,3]');
    });
  });

  group('formatGetTimeSuccess', () {
    test('renders headline / continuation with samples, bound, trust', () {
      final synced = NtsSyncedTime(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 35_650,
        samplesUsed: 3,
        errorBoundMicros: 21_000,
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
      // Worst-case bound is errorBoundMicros (RFC 5905 root
      // distance) through formatRtt.
      expect(lines[1], contains('error≤±21.00ms (root distance)'));
      expect(lines[1], contains('trust=platform'));
    });

    test('falls back to RTT/2 when built from a pre-7.1 fixture', () {
      final synced = NtsSyncedTime(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 35_650,
        samplesUsed: 1,
        trustBackend: TrustBackend.platform,
      );
      final out = formatGetTimeSuccess(synced);
      // Constructor default: errorBoundMicros = roundTripMicros ~/ 2.
      expect(out, contains('error≤±17.82ms (root distance)'));
    });
  });

  group('NtsError severity + description', () {
    test('classifies severity for every NtsError shape', () {
      for (final err in _allNtsErrors) {
        expect(
          isErrorSeverity(err),
          _expectedErrorSeverity(_variantKind(err)),
          reason: errorTypeName(err),
        );
      }
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

    test('describe leads with the variant tag for every NtsError shape', () {
      for (final err in _allNtsErrors) {
        expect(describeError(err), startsWith(errorTypeName(err)));
      }
    });
  });

  group('errorTypeName', () {
    test('returns the stable variant tag for every NtsError shape', () {
      for (final err in _allNtsErrors) {
        expect(errorTypeName(err), _expectedTag(_variantKind(err)));
      }
    });

    test('assigns a distinct tag to every NtsError variant', () {
      expect(
        _allNtsErrors.map(errorTypeName).toSet(),
        hasLength(_allNtsErrors.length),
      );
    });
  });

  group('timeoutPhaseName', () {
    test('returns the phase name for every Timeout phase', () {
      for (final phase in TimeoutPhase.values) {
        expect(timeoutPhaseName(NtsError.timeout(phase: phase)), phase.name);
      }
    });

    test('returns null for every non-Timeout shape', () {
      for (final err in _nonTimeoutErrors) {
        expect(timeoutPhaseName(err), isNull, reason: errorTypeName(err));
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
        // Present unconditionally, empty in the common case, so
        // consumers can index the key without a presence branch.
        'ke_warnings': <int>[],
      });
    });

    test('carries the raw ke_warnings codes when the server sent any', () {
      final sample = NtsTimeSample(
        utcUnixMicros: 1_777_334_400 * 1000000,
        roundTripMicros: 750,
        serverStratum: 1,
        aeadId: 15,
        freshCookies: 2,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
        keWarnings: const [1, 4097],
      );
      expect(jsonQuerySuccess(sample)['ke_warnings'], [1, 4097]);
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
        'ke_warnings': <int>[],
      });
    });

    test('carries the raw ke_warnings codes when the server sent any', () {
      final outcome = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: _zeroPhaseTimings(),
        trustBackend: TrustBackend.platform,
        keWarnings: const [7],
      );
      expect(jsonWarmSuccess(outcome)['ke_warnings'], [7]);
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
      for (final err in _nonTimeoutErrors) {
        expect(
          jsonError(err),
          isNot(contains('phase')),
          reason: errorTypeName(err),
        );
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

  group('formatDnsPoolStats', () {
    test('renders cumulative counters as a before/after delta', () {
      final text = formatDnsPoolStats(
        _poolStats(recovered: 10, refused: 2, spawnFailed: 1),
        _poolStats(recovered: 14, refused: 5, spawnFailed: 3),
      );
      final lines = text.split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], 'DNS pool  refused=3  spawn-failed=2');
      expect(lines[1], contains('recovered=4'));
    });

    test('renders in-flight and high-water absolutely, not as deltas', () {
      // Subtracting a live gauge or a process-lifetime maximum would
      // produce a number with no meaning, so both stay absolute.
      final text = formatDnsPoolStats(
        _poolStats(inFlight: 1, highWaterMark: 3),
        _poolStats(inFlight: 2, highWaterMark: 7),
      );
      expect(text, contains('in-flight=2'));
      expect(text, contains('high-water=7 (process lifetime)'));
    });
  });

  group('jsonDnsPoolStats', () {
    test('deltas the counters and passes the gauges through', () {
      expect(
        jsonDnsPoolStats(
          _poolStats(
            inFlight: 1,
            highWaterMark: 3,
            recovered: 10,
            refused: 2,
            spawnFailed: 1,
          ),
          _poolStats(
            inFlight: 2,
            highWaterMark: 7,
            recovered: 14,
            refused: 5,
            spawnFailed: 3,
          ),
        ),
        {
          'refused': 3,
          'spawn_failed': 2,
          'recovered': 4,
          'in_flight': 2,
          'high_water_mark': 7,
        },
      );
    });

    test('an untouched pool reports an all-zero delta', () {
      final stats = _poolStats(recovered: 10, refused: 2, spawnFailed: 1);
      final payload = jsonDnsPoolStats(stats, stats);
      expect(payload['refused'], 0);
      expect(payload['spawn_failed'], 0);
      expect(payload['recovered'], 0);
    });

    test('payload survives a jsonEncode round trip', () {
      final payload = jsonDnsPoolStats(_poolStats(), _poolStats(refused: 1));
      expect(jsonDecode(jsonEncode(payload)), payload);
    });
  });

  group('_allNtsErrors', () {
    test('covers every NtsError variant exactly once', () {
      expect(_allNtsErrors.map(_variantKind), _NtsErrorKind.values);
    });
  });
}

NtsDnsPoolStats _poolStats({
  int inFlight = 0,
  int highWaterMark = 0,
  int recovered = 0,
  int refused = 0,
  int spawnFailed = 0,
}) => NtsDnsPoolStats(
  inFlight: inFlight,
  highWaterMark: highWaterMark,
  recovered: recovered,
  refused: refused,
  spawnFailed: spawnFailed,
);

PhaseTimings _zeroPhaseTimings() => const PhaseTimings(
  dnsMicros: 0,
  connectMicros: 0,
  tlsHandshakeMicros: 0,
  keRecordIoMicros: 0,
);

/// One kind per concrete `NtsError` subclass.
///
/// Exists so [_variantKind]'s switch can be exhaustive over the sealed
/// type while [_allNtsErrors]' completeness stays checkable at runtime:
/// the enum is the pivot both halves are compared against.
enum _NtsErrorKind {
  invalidSpec,
  network,
  keProtocol,
  ntpProtocol,
  authentication,
  timeout,
  noCookies,
  trustBackendUnavailable,
  internal,
  abiMismatch,
}

/// Kind of [err]'s variant.
///
/// Exhaustive over the sealed `NtsError` type with no default or
/// wildcard arm, so adding a variant to `lib/src/api/errors.dart` is a
/// `dart analyze` error here rather than a silently under-checking
/// test.
_NtsErrorKind _variantKind(NtsError err) => switch (err) {
  NtsErrorInvalidSpec() => _NtsErrorKind.invalidSpec,
  NtsErrorNetwork() => _NtsErrorKind.network,
  NtsErrorKeProtocol() => _NtsErrorKind.keProtocol,
  NtsErrorNtpProtocol() => _NtsErrorKind.ntpProtocol,
  NtsErrorAuthentication() => _NtsErrorKind.authentication,
  NtsErrorTimeout() => _NtsErrorKind.timeout,
  NtsErrorNoCookies() => _NtsErrorKind.noCookies,
  NtsErrorTrustBackendUnavailable() => _NtsErrorKind.trustBackendUnavailable,
  NtsErrorInternal() => _NtsErrorKind.internal,
  NtsErrorAbiMismatch() => _NtsErrorKind.abiMismatch,
};

/// One sample instance of every `NtsError` variant, for tests that
/// assert a property over the whole sealed hierarchy.
///
/// Dart has no reflection over sealed subtypes, so the instances are
/// constructed by hand. Two guards keep the list honest: [_variantKind]
/// fails analysis when a variant is added to the sealed type, and the
/// `_allNtsErrors` group above fails when a kind has no sample here.
const _allNtsErrors = <NtsError>[
  NtsError.invalidSpec(message: 'x'),
  NtsError.network(message: 'x'),
  NtsError.keProtocol(message: 'x'),
  NtsError.ntpProtocol(message: 'x'),
  NtsError.authentication(message: 'x'),
  NtsError.timeout(phase: TimeoutPhase.ntp),
  NtsError.noCookies(),
  NtsError.trustBackendUnavailable(message: 'x'),
  NtsError.internal(message: 'x'),
  NtsError.abiMismatch(message: 'x'),
];

/// Every [_allNtsErrors] sample except the `Timeout` variant.
///
/// Derived rather than hand-listed so the "no phase key" assertions
/// pick up new variants automatically; both call sites had already
/// drifted from the hierarchy when they were literal lists.
final _nonTimeoutErrors = _allNtsErrors
    .where((err) => _variantKind(err) != _NtsErrorKind.timeout)
    .toList();

/// Public tag [errorTypeName] must emit for [kind].
///
/// Exhaustive over [_NtsErrorKind] with no default arm, so a new
/// variant cannot reach the CLI without someone pinning the tag its
/// JSON output will carry. The tags are a public contract: consumers
/// match on them, so a rename is a breaking change and is meant to
/// require an edit here.
String _expectedTag(_NtsErrorKind kind) => switch (kind) {
  _NtsErrorKind.invalidSpec => 'InvalidSpec',
  _NtsErrorKind.network => 'Network',
  _NtsErrorKind.keProtocol => 'KeProtocol',
  _NtsErrorKind.ntpProtocol => 'NtpProtocol',
  _NtsErrorKind.authentication => 'Authentication',
  _NtsErrorKind.timeout => 'Timeout',
  _NtsErrorKind.noCookies => 'NoCookies',
  _NtsErrorKind.trustBackendUnavailable => 'TrustBackendUnavailable',
  _NtsErrorKind.internal => 'Internal',
  _NtsErrorKind.abiMismatch => 'AbiMismatch',
};

/// Whether [kind] is error-severity rather than warn-severity.
///
/// Exhaustive over [_NtsErrorKind] with no default arm, so a new
/// variant forces an explicit severity decision instead of inheriting
/// whatever `isErrorSeverity` happens to fall through to.
bool _expectedErrorSeverity(_NtsErrorKind kind) => switch (kind) {
  // Transient or caller-input conditions: a retry or a corrected
  // argument can resolve them without operator involvement.
  _NtsErrorKind.network ||
  _NtsErrorKind.timeout ||
  _NtsErrorKind.invalidSpec ||
  _NtsErrorKind.noCookies => false,
  // TrustBackendUnavailable is a deliberate caller-side configuration
  // choice (`PlatformOnly`) the runtime cannot honour; classified as
  // error so an operator notices the misconfiguration rather than
  // treating it as a transient network blip.
  _NtsErrorKind.authentication ||
  _NtsErrorKind.keProtocol ||
  _NtsErrorKind.ntpProtocol ||
  _NtsErrorKind.trustBackendUnavailable ||
  _NtsErrorKind.internal ||
  _NtsErrorKind.abiMismatch => true,
};
