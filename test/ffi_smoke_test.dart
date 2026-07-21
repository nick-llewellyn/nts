// Smoke test for the flutter_rust_bridge codegen pipeline.
//
// Validates that:
//   1. Codegen produced Dart bindings for the NTS surface (`ntsQuery`,
//      `ntsWarmCookies`).
//   2. The bindings carry the expected signatures and that calls dispatch
//      through `NtsRustLibApi` so mock implementations can intercept them.
//   3. The bridge can be initialized in mock mode without loading the
//      native dylib (Native Assets bundling is covered separately).

// This test deliberately exercises the FRB layer directly — it is the
// contract test for the codegen pipeline, not for the hand-written
// wrapper in `lib/src/api/`. All types and functions are imported from
// the FFI module so the signatures asserted here are FRB's, not the
// wrapper's. The companion wrapper-layer smoke test lives in
// `test/api_smoke_test.dart`.
// ignore_for_file: implementation_imports

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/src/ffi/api/nts.dart'
    show
        NtsError,
        NtsServerSpec,
        NtsTimeSample,
        NtsWarmCookiesOutcome,
        PhaseTimings,
        TimeoutPhase,
        TrustBackend,
        ntsQuery,
        ntsWarmCookies;
import 'package:nts/src/ffi/frb_generated.dart';

class _FakeNtsRustLibApi implements NtsRustLibApi {
  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  Future<NtsTimeSample> crateApiNtsNtsQuery({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) async => NtsTimeSample(
    utcUnixMicros: PlatformInt64Util.from(1_777_334_400 * 1000000),
    roundTripMicros: PlatformInt64Util.from(12_500),
    serverStratum: 1,
    aeadId: 15,
    freshCookies: 1,
    phaseTimings: _zeroPhaseTimings(),
    trustBackend: TrustBackend.platform,
    recvBoottimeMicros: PlatformInt64Util.from(0),
    offsetMicros: PlatformInt64Util.from(0),
    peerDelayMicros: PlatformInt64Util.from(0),
    rootDelayMicros: PlatformInt64Util.from(0),
    rootDispersionMicros: PlatformInt64Util.from(0),
    serverPrecision: 0,
  );

  @override
  Future<NtsWarmCookiesOutcome> crateApiNtsNtsWarmCookies({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) async => NtsWarmCookiesOutcome(
    freshCookies: 8,
    phaseTimings: _zeroPhaseTimings(),
    trustBackend: TrustBackend.platform,
  );

  @override
  Future<PhaseTimings> crateApiNtsPhaseTimingsDefault() async =>
      _zeroPhaseTimings();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('mock api: ${invocation.memberName} not stubbed');
}

PhaseTimings _zeroPhaseTimings() => PhaseTimings(
  dnsMicros: PlatformInt64Util.from(0),
  connectMicros: PlatformInt64Util.from(0),
  tlsHandshakeMicros: PlatformInt64Util.from(0),
  keRecordIoMicros: PlatformInt64Util.from(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    NtsRustLib.initMock(api: _FakeNtsRustLibApi());
  });

  group('FRB toolchain smoke test', () {
    test('ntsQuery() dispatches through the mock api', () async {
      const spec = NtsServerSpec(host: 'time.example', port: 4460);
      // FFI surface: every parameter is `required` per FRB v2 codegen,
      // so the wrapper-layer omission convenience does not apply here.
      // The literal `4` is an arbitrary in-range non-zero value chosen
      // because `_FakeNtsRustLibApi` ignores the parameter; this file
      // intentionally imports nothing from the public layer (see the
      // file-level comment), so the wrapper's `kDefaultDnsConcurrencyCap`
      // is deliberately not referenced here.
      final sample = await ntsQuery(
        spec: spec,
        timeoutMs: 5000,
        dnsConcurrencyCap: 4,
      );
      expect(sample.aeadId, 15);
      expect(sample.serverStratum, 1);
      expect(sample.freshCookies, 1);
      expect(sample.roundTripMicros.toInt(), 12_500);
    });

    test('ntsWarmCookies() dispatches through the mock api', () async {
      const spec = NtsServerSpec(host: 'time.example', port: 4460);
      // See the comment on the matching ntsQuery test above for why
      // `dnsConcurrencyCap` is hard-coded rather than omitted here.
      final outcome = await ntsWarmCookies(
        spec: spec,
        timeoutMs: 5000,
        dnsConcurrencyCap: 4,
      );
      expect(outcome.freshCookies, 8);
      expect(outcome.phaseTimings, isA<PhaseTimings>());
    });

    test('NtsError variants construct and equality is value-based', () {
      const a = NtsError.timeout(phase: TimeoutPhase.ntp);
      const b = NtsError.timeout(phase: TimeoutPhase.ntp);
      const c = NtsError.invalidSpec('host empty');
      const d = NtsError.timeout(phase: TimeoutPhase.dnsSaturation);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
      expect(c.toString(), contains('host empty'));
    });
  });
}
