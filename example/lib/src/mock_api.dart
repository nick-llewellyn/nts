// The example needs to construct a `RustLibApi` instance to feed
// `RustLib.initMock`, but `RustLibApi` is intentionally not part of the
// public barrel — it's an internal contract that exists only so unit
// tests and showcase apps can stub the bridge without loading a dylib.
// The same pattern is used in `test/ffi_smoke_test.dart`.
// ignore_for_file: implementation_imports

import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:nts/src/ffi/frb_generated.dart' show RustLibApi;
import 'package:nts/nts.dart' show NtsError, NtsServerSpec, NtsTimeSample;

/// In-memory `RustLibApi` implementation used by the example app and the
/// widget smoke test as an explicit alternative to the bundled Rust dylib.
///
/// Returns plausible-looking NTS samples so the UI is exercisable on any
/// host without TLS/UDP plumbing. The example launches against the real
/// bridge by default; pass `--dart-define=NTS_BRIDGE=mock` to bind this
/// fake implementation instead (handy for offline UI work or for hosts
/// where the Rust toolchain isn't set up).
class MockNtsApi implements RustLibApi {
  MockNtsApi({Random? random}) : _random = random ?? Random();

  final Random _random;

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  Future<NtsTimeSample> crateApiNtsNtsQuery({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    // Simulate a realistic TLS+UDP RTT so the UI feels live.
    final rttMs = 25 + _random.nextInt(40);
    await Future<void>.delayed(Duration(milliseconds: rttMs));

    // 0.5% of mock calls fail with an authentication error so devs can
    // exercise the NtsError rendering path without a real server.
    if (_random.nextInt(200) == 0) {
      throw const NtsError.authentication('mock: synthetic AEAD tag mismatch');
    }

    final nowMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return NtsTimeSample(
      utcUnixMicros: PlatformInt64Util.from(nowMicros),
      roundTripMicros: PlatformInt64Util.from(rttMs * 1000),
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
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return 8;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'MockNtsApi: ${invocation.memberName} not stubbed',
  );
}
