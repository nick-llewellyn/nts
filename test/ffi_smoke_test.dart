// Smoke test for the flutter_rust_bridge codegen pipeline.
//
// Validates that:
//   1. Codegen produced Dart bindings for the NTS surface (`ntsQuery`,
//      `ntsWarmCookies`).
//   2. The bindings carry the expected signatures and that calls dispatch
//      through `RustLibApi` so mock implementations can intercept them.
//   3. The bridge can be initialized in mock mode without loading the
//      native dylib (Native Assets bundling is covered separately in
//      `trusted_time-eg9`).

// This test deliberately exercises the FRB layer directly — it is the
// contract test for the codegen pipeline, not for the hand-written
// wrapper in `lib/src/api/`. `ntsQuery` / `ntsWarmCookies` are imported
// from the FFI module so the signatures asserted here are FRB's, not
// the wrapper's. The companion wrapper-layer smoke test lives in
// `test/api_smoke_test.dart`.
// ignore_for_file: implementation_imports

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' show NtsError, NtsServerSpec, NtsTimeSample;
import 'package:nts/src/ffi/api/nts.dart' show ntsQuery, ntsWarmCookies;
import 'package:nts/src/ffi/frb_generated.dart';

class _FakeRustLibApi implements RustLibApi {
  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  Future<NtsTimeSample> crateApiNtsNtsQuery({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async => NtsTimeSample(
    utcUnixMicros: PlatformInt64Util.from(1_777_334_400 * 1000000),
    roundTripMicros: PlatformInt64Util.from(12_500),
    serverStratum: 1,
    aeadId: 15,
    freshCookies: 1,
  );

  @override
  Future<int> crateApiNtsNtsWarmCookies({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async => 8;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('mock api: ${invocation.memberName} not stubbed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    RustLib.initMock(api: _FakeRustLibApi());
  });

  group('FRB toolchain smoke test', () {
    test('ntsQuery() dispatches through the mock api', () async {
      const spec = NtsServerSpec(host: 'time.example', port: 4460);
      final sample = await ntsQuery(
        spec: spec,
        timeoutMs: 5000,
        dnsConcurrencyCap: 0,
      );
      expect(sample.aeadId, 15);
      expect(sample.serverStratum, 1);
      expect(sample.freshCookies, 1);
      expect(sample.roundTripMicros.toInt(), 12_500);
    });

    test('ntsWarmCookies() dispatches through the mock api', () async {
      const spec = NtsServerSpec(host: 'time.example', port: 4460);
      final count = await ntsWarmCookies(
        spec: spec,
        timeoutMs: 5000,
        dnsConcurrencyCap: 0,
      );
      expect(count, 8);
    });

    test('NtsError variants construct and equality is value-based', () {
      const a = NtsError.timeout();
      const b = NtsError.timeout();
      const c = NtsError.invalidSpec('host empty');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(c.toString(), contains('host empty'));
    });
  });
}
