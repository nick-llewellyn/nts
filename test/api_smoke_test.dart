// Smoke test for the hand-written public-API wrapper in
// `lib/src/api/nts.dart`.
//
// Validates that:
//   1. Optional parameters (`timeoutMs`, `dnsConcurrencyCap`) get their
//      package defaults applied when omitted, matching what 1.2.0
//      callers got by passing the values explicitly.
//   2. Caller-supplied overrides are forwarded verbatim to the FRB
//      layer, including the `dnsConcurrencyCap = 0` sentinel.
//   3. The exported `kDefault*` constants line up with the
//      pre-1.3.0 behaviour pinned by `test/ffi_smoke_test.dart`.
//   4. The conversion layer maps FFI DTOs (with `PlatformInt64`
//      microsecond fields) onto public DTOs (plain `int`), and FFI
//      `NtsError` variants onto the hand-written public sealed class.
//
// The companion FRB toolchain smoke test (`test/ffi_smoke_test.dart`)
// exercises the underlying generated bindings directly and is kept
// separate as a contract test on the codegen pipeline.
//
// ignore_for_file: implementation_imports

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart';
import 'package:nts/src/ffi/api/nts.dart' as ffi;
import 'package:nts/src/ffi/frb_generated.dart';

class _RecordingApi implements RustLibApi {
  int? lastQueryTimeoutMs;
  int? lastQueryDnsCap;
  int? lastWarmTimeoutMs;
  int? lastWarmDnsCap;
  int dnsPoolStatsCalls = 0;
  // Pinned FFI values returned by the mock. Tests assert that the
  // wrapper converts these into the matching public DTOs.
  ffi.NtsTimeSample nextSample = _ffiSample();
  ffi.NtsWarmCookiesOutcome nextWarm = _ffiWarm(0);
  ffi.NtsDnsPoolStats nextDnsPoolStats = _zeroFfiDnsPoolStats();
  Object? nextThrow;

  void reset() {
    lastQueryTimeoutMs = null;
    lastQueryDnsCap = null;
    lastWarmTimeoutMs = null;
    lastWarmDnsCap = null;
    dnsPoolStatsCalls = 0;
    nextSample = _ffiSample();
    nextWarm = _ffiWarm(0);
    nextDnsPoolStats = _zeroFfiDnsPoolStats();
    nextThrow = null;
  }

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsQuery({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    lastQueryTimeoutMs = timeoutMs;
    lastQueryDnsCap = dnsConcurrencyCap;
    final t = nextThrow;
    if (t != null) throw t;
    return nextSample;
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsWarmCookies({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    lastWarmTimeoutMs = timeoutMs;
    lastWarmDnsCap = dnsConcurrencyCap;
    final t = nextThrow;
    if (t != null) throw t;
    return nextWarm;
  }

  @override
  Future<ffi.PhaseTimings> crateApiNtsPhaseTimingsDefault() async =>
      _zeroFfiPhaseTimings();

  @override
  ffi.NtsDnsPoolStats crateApiNtsNtsDnsPoolStats() {
    dnsPoolStatsCalls++;
    return nextDnsPoolStats;
  }

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('mock api: ${invocation.memberName} not stubbed');
}

ffi.PhaseTimings _zeroFfiPhaseTimings() => ffi.PhaseTimings(
  dnsMicros: PlatformInt64Util.from(0),
  connectMicros: PlatformInt64Util.from(0),
  tlsHandshakeMicros: PlatformInt64Util.from(0),
  keRecordIoMicros: PlatformInt64Util.from(0),
);

ffi.NtsTimeSample _ffiSample({
  int utcUnixMicros = 0,
  int roundTripMicros = 0,
  int serverStratum = 1,
  int aeadId = 15,
  int freshCookies = 1,
  ffi.PhaseTimings? phaseTimings,
}) => ffi.NtsTimeSample(
  utcUnixMicros: PlatformInt64Util.from(utcUnixMicros),
  roundTripMicros: PlatformInt64Util.from(roundTripMicros),
  serverStratum: serverStratum,
  aeadId: aeadId,
  freshCookies: freshCookies,
  phaseTimings: phaseTimings ?? _zeroFfiPhaseTimings(),
);

ffi.NtsWarmCookiesOutcome _ffiWarm(int cookies) => ffi.NtsWarmCookiesOutcome(
  freshCookies: cookies,
  phaseTimings: _zeroFfiPhaseTimings(),
);

ffi.NtsDnsPoolStats _zeroFfiDnsPoolStats() => ffi.NtsDnsPoolStats(
  inFlight: 0,
  highWaterMark: 0,
  recovered: BigInt.zero,
  refused: BigInt.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `RustLib.initMock` rejects a second call within a single test process,
  // so the mock is wired exactly once and its recording state is cleared
  // between tests instead.
  final api = _RecordingApi();

  setUpAll(() {
    RustLib.initMock(api: api);
  });

  setUp(api.reset);

  group('public API stability layer', () {
    const spec = NtsServerSpec(host: 'time.example', port: 4460);

    test('exported defaults match the pre-1.3.0 behaviour', () {
      expect(kDefaultTimeoutMs, 5000);
      expect(kDefaultDnsConcurrencyCap, 0);
    });

    test(
      'ntsQuery applies the package defaults when args are omitted',
      () async {
        await ntsQuery(spec: spec);
        expect(api.lastQueryTimeoutMs, kDefaultTimeoutMs);
        expect(api.lastQueryDnsCap, kDefaultDnsConcurrencyCap);
      },
    );

    test('ntsQuery forwards explicit overrides verbatim', () async {
      await ntsQuery(spec: spec, timeoutMs: 1234, dnsConcurrencyCap: 32);
      expect(api.lastQueryTimeoutMs, 1234);
      expect(api.lastQueryDnsCap, 32);
    });

    test('ntsQuery preserves the `0` sentinel on dnsConcurrencyCap', () async {
      await ntsQuery(spec: spec, timeoutMs: 7777, dnsConcurrencyCap: 0);
      expect(api.lastQueryTimeoutMs, 7777);
      expect(api.lastQueryDnsCap, 0);
    });

    test(
      'ntsWarmCookies applies the package defaults when args are omitted',
      () async {
        await ntsWarmCookies(spec: spec);
        expect(api.lastWarmTimeoutMs, kDefaultTimeoutMs);
        expect(api.lastWarmDnsCap, kDefaultDnsConcurrencyCap);
      },
    );

    test('ntsWarmCookies forwards explicit overrides verbatim', () async {
      await ntsWarmCookies(spec: spec, timeoutMs: 9000, dnsConcurrencyCap: 16);
      expect(api.lastWarmTimeoutMs, 9000);
      expect(api.lastWarmDnsCap, 16);
    });

    test('ntsDnsPoolStats is synchronous and converts the FFI struct', () {
      api.nextDnsPoolStats = ffi.NtsDnsPoolStats(
        inFlight: 3,
        highWaterMark: 7,
        recovered: BigInt.from(42),
        refused: BigInt.from(2),
      );
      // Sync: the call must return a value, not a Future.
      final stats = ntsDnsPoolStats();
      expect(stats, isA<NtsDnsPoolStats>());
      expect(api.dnsPoolStatsCalls, 1);
      expect(stats.inFlight, 3);
      expect(stats.highWaterMark, 7);
      expect(stats.recovered, BigInt.from(42));
      expect(stats.refused, BigInt.from(2));
    });
  });

  group('FFI -> public conversion', () {
    const spec = NtsServerSpec(host: 'time.example', port: 4460);

    test('ntsQuery surfaces a public NtsTimeSample with int fields', () async {
      api.nextSample = _ffiSample(
        utcUnixMicros: 1_777_334_400_000_000,
        roundTripMicros: 12_500,
        serverStratum: 2,
        aeadId: 30,
        freshCookies: 7,
        phaseTimings: ffi.PhaseTimings(
          dnsMicros: PlatformInt64Util.from(11_111),
          connectMicros: PlatformInt64Util.from(22_222),
          tlsHandshakeMicros: PlatformInt64Util.from(33_333),
          keRecordIoMicros: PlatformInt64Util.from(44_444),
        ),
      );
      final sample = await ntsQuery(spec: spec);
      expect(sample, isA<NtsTimeSample>());
      // Plain Dart `int`, not `PlatformInt64`. `is int` is the
      // strongest check available because `PlatformInt64`'s native
      // alias also reports as `int`; the contract is "no member that
      // requires a PlatformInt64-shaped wrapper".
      expect(sample.utcUnixMicros, 1_777_334_400_000_000);
      expect(sample.roundTripMicros, 12_500);
      expect(sample.serverStratum, 2);
      expect(sample.aeadId, 30);
      expect(sample.freshCookies, 7);
      expect(sample.phaseTimings.dnsMicros, 11_111);
      expect(sample.phaseTimings.connectMicros, 22_222);
      expect(sample.phaseTimings.tlsHandshakeMicros, 33_333);
      expect(sample.phaseTimings.keRecordIoMicros, 44_444);
    });

    test('ntsWarmCookies surfaces a public NtsWarmCookiesOutcome', () async {
      api.nextWarm = ffi.NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: _zeroFfiPhaseTimings(),
      );
      final outcome = await ntsWarmCookies(spec: spec);
      expect(outcome, isA<NtsWarmCookiesOutcome>());
      expect(outcome.freshCookies, 8);
      expect(outcome.phaseTimings, isA<PhaseTimings>());
    });

    test('deprecated underscore-prefixed typedefs alias the new names', () {
      // The 3.0 rename retains the pre-3.0 freezed-style names as
      // deprecated typedefs for one release. The deprecation is
      // intentional; the lint suppression below is scoped to this
      // single test so any *real* use of the old names elsewhere in
      // the package still trips the warning.
      // ignore: deprecated_member_use_from_same_package
      const NtsError_InvalidSpec a = NtsErrorInvalidSpec('x');
      // ignore: deprecated_member_use_from_same_package
      const NtsError_NoCookies b = NtsErrorNoCookies();
      // ignore: deprecated_member_use_from_same_package
      const NtsError_Timeout c = NtsErrorTimeout(TimeoutPhase.ntp);
      expect(a, isA<NtsErrorInvalidSpec>());
      expect(b, isA<NtsErrorNoCookies>());
      expect(c, isA<NtsErrorTimeout>());
    });

    test(
      'ntsQuery converts every FFI NtsError variant to its public twin',
      () async {
        final cases = <(ffi.NtsError, NtsError)>[
          (
            const ffi.NtsError.invalidSpec('bad'),
            const NtsError.invalidSpec('bad'),
          ),
          (const ffi.NtsError.network('eof'), const NtsError.network('eof')),
          (
            const ffi.NtsError.keProtocol('tls'),
            const NtsError.keProtocol('tls'),
          ),
          (
            const ffi.NtsError.ntpProtocol('kod'),
            const NtsError.ntpProtocol('kod'),
          ),
          (
            const ffi.NtsError.authentication('mac'),
            const NtsError.authentication('mac'),
          ),
          (
            const ffi.NtsError.timeout(ffi.TimeoutPhase.ntp),
            const NtsError.timeout(TimeoutPhase.ntp),
          ),
          (
            const ffi.NtsError.timeout(ffi.TimeoutPhase.dnsSaturation),
            const NtsError.timeout(TimeoutPhase.dnsSaturation),
          ),
          (const ffi.NtsError.noCookies(), const NtsError.noCookies()),
          (
            const ffi.NtsError.internal('panic'),
            const NtsError.internal('panic'),
          ),
        ];
        for (final (ffiErr, publicErr) in cases) {
          api.nextThrow = ffiErr;
          await expectLater(
            ntsQuery(spec: spec),
            throwsA(predicate<Object>((e) => e is NtsError && e == publicErr)),
          );
        }
      },
    );
  });
}
