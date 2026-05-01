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
import 'package:nts/src/ffi/frb_generated.dart';

class _RecordingApi implements RustLibApi {
  int? lastQueryTimeoutMs;
  int? lastQueryDnsCap;
  int? lastWarmTimeoutMs;
  int? lastWarmDnsCap;
  int dnsPoolStatsCalls = 0;
  // Pinned values returned by `crateApiNtsNtsDnsPoolStats` so tests
  // can assert the wrapper plumbs the FFI struct through verbatim.
  NtsDnsPoolStats nextDnsPoolStats = NtsDnsPoolStats(
    inFlight: 0,
    highWaterMark: 0,
    recovered: BigInt.zero,
    refused: BigInt.zero,
  );

  void reset() {
    lastQueryTimeoutMs = null;
    lastQueryDnsCap = null;
    lastWarmTimeoutMs = null;
    lastWarmDnsCap = null;
    dnsPoolStatsCalls = 0;
  }

  @override
  Future<NtsTimeSample> crateApiNtsNtsQuery({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    lastQueryTimeoutMs = timeoutMs;
    lastQueryDnsCap = dnsConcurrencyCap;
    return NtsTimeSample(
      utcUnixMicros: PlatformInt64Util.from(0),
      roundTripMicros: PlatformInt64Util.from(0),
      serverStratum: 1,
      aeadId: 15,
      freshCookies: 1,
    );
  }

  @override
  Future<int> crateApiNtsNtsWarmCookies({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    lastWarmTimeoutMs = timeoutMs;
    lastWarmDnsCap = dnsConcurrencyCap;
    return 0;
  }

  @override
  NtsDnsPoolStats crateApiNtsNtsDnsPoolStats() {
    dnsPoolStatsCalls++;
    return nextDnsPoolStats;
  }

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('mock api: ${invocation.memberName} not stubbed');
}

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

    test('ntsDnsPoolStats is synchronous and forwards the FFI struct', () {
      api.nextDnsPoolStats = NtsDnsPoolStats(
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
}
