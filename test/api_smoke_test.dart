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
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

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

  // Per-`NtsClient`-method recording. Distinct from the top-level
  // `lastQuery*` / `lastWarm*` fields above so a test that exercises
  // both surfaces can assert on each one independently. The `last*That`
  // fields hold the opaque `that:` handle the public wrapper passed
  // through, used by the isolation test to assert that two `NtsClient`
  // instances forward through distinct FFI handles.
  ffi.NtsClient? lastClientQueryThat;
  int? lastClientQueryTimeoutMs;
  int? lastClientQueryDnsCap;
  ffi.NtsClient? lastClientWarmThat;
  int? lastClientWarmTimeoutMs;
  int? lastClientWarmDnsCap;
  ffi.NtsClient? lastClientInvalidateThat;
  ffi.NtsServerSpec? lastClientInvalidateSpec;
  ffi.NtsClient? lastClientClearThat;
  int clientNewCalls = 0;
  int clientClearCalls = 0;
  int clientInvalidateCalls = 0;
  // Return value the mock hands back from the next
  // `crateApiNtsNtsClientInvalidate` call. Defaults to `false` so a
  // test that does not override it gets the documented "no entry was
  // cached" semantics.
  bool nextInvalidateResult = false;

  // --- Trust-anchor diagnostics surface ----------------------------
  //
  // `crateApiNtsNtsClientWithTrustMode` records the requested mode
  // and pins it to the minted fake handle so the wrapper's
  // `client.trustMode` getter (which dispatches through
  // `crateApiNtsNtsClientTrustMode`) round-trips the construction
  // choice. `crateApiNtsNtsTrustStatus` returns `nextTrustStatus`,
  // defaulting to a sentinel snapshot (no handshake observed) so a
  // test that does not override it gets the documented "process just
  // started" shape.
  int clientWithTrustModeCalls = 0;
  ffi.TrustMode? lastClientWithTrustModeMode;
  final Map<ffi.NtsClient, ffi.TrustMode> clientTrustModes =
      <ffi.NtsClient, ffi.TrustMode>{};
  int trustStatusCalls = 0;
  ffi.NtsTrustStatus nextTrustStatus = _zeroFfiTrustStatus();

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
    lastClientQueryThat = null;
    lastClientQueryTimeoutMs = null;
    lastClientQueryDnsCap = null;
    lastClientWarmThat = null;
    lastClientWarmTimeoutMs = null;
    lastClientWarmDnsCap = null;
    lastClientInvalidateThat = null;
    lastClientInvalidateSpec = null;
    lastClientClearThat = null;
    clientNewCalls = 0;
    clientClearCalls = 0;
    clientInvalidateCalls = 0;
    nextInvalidateResult = false;
    clientWithTrustModeCalls = 0;
    lastClientWithTrustModeMode = null;
    clientTrustModes.clear();
    trustStatusCalls = 0;
    nextTrustStatus = _zeroFfiTrustStatus();
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

  // --- NtsClient surface ----------------------------------------------
  //
  // `crateApiNtsNtsClientNew` returns a `_FakeFfiNtsClient` so the
  // public `NtsClient` wrapper has a `that:` handle to forward through
  // the four method stubs below. The fake re-routes its own method
  // calls back to this `_RecordingApi` (see `_FakeFfiNtsClient` for the
  // forwarding indirection), giving the mock end-to-end visibility
  // even though no real `RustOpaque` arc exists on the test side.

  @override
  ffi.NtsClient crateApiNtsNtsClientNew() {
    clientNewCalls++;
    final fake = _FakeFfiNtsClient();
    // Default-constructed clients always carry the fallback policy on
    // the Rust side; pin the same view here so a subsequent
    // `client.trustMode` getter forwards through and reads back the
    // documented default rather than tripping the noSuchMethod guard.
    clientTrustModes[fake] = ffi.TrustMode.platformWithFallback;
    return fake;
  }

  @override
  ffi.NtsClient crateApiNtsNtsClientWithTrustMode({
    required ffi.TrustMode trustMode,
  }) {
    clientWithTrustModeCalls++;
    lastClientWithTrustModeMode = trustMode;
    final fake = _FakeFfiNtsClient();
    clientTrustModes[fake] = trustMode;
    return fake;
  }

  @override
  ffi.TrustMode crateApiNtsNtsClientTrustMode({required ffi.NtsClient that}) =>
      clientTrustModes[that] ?? ffi.TrustMode.platformWithFallback;

  @override
  ffi.NtsTrustStatus crateApiNtsNtsTrustStatus() {
    trustStatusCalls++;
    return nextTrustStatus;
  }

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsClientQuery({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    lastClientQueryThat = that;
    lastClientQueryTimeoutMs = timeoutMs;
    lastClientQueryDnsCap = dnsConcurrencyCap;
    final t = nextThrow;
    if (t != null) throw t;
    return nextSample;
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsClientWarmCookies({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    lastClientWarmThat = that;
    lastClientWarmTimeoutMs = timeoutMs;
    lastClientWarmDnsCap = dnsConcurrencyCap;
    final t = nextThrow;
    if (t != null) throw t;
    return nextWarm;
  }

  @override
  bool crateApiNtsNtsClientInvalidate({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
  }) {
    clientInvalidateCalls++;
    lastClientInvalidateThat = that;
    lastClientInvalidateSpec = spec;
    return nextInvalidateResult;
  }

  @override
  void crateApiNtsNtsClientClear({required ffi.NtsClient that}) {
    clientClearCalls++;
    lastClientClearThat = that;
  }

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('mock api: ${invocation.memberName} not stubbed');
}

// In-memory stand-in for `ffi.NtsClient`. The public `NtsClient`
// wrapper holds one of these as its `_inner` field whenever
// `_RecordingApi.crateApiNtsNtsClientNew` is the active mock; the
// fake re-routes each `clear` / `invalidate` / `query` / `warmCookies`
// call back through `RustLib.instance.api`, which is the same
// `_RecordingApi` instance, so the mock observes the call exactly as
// the real `NtsClientImpl` would have routed it. `dispose` /
// `isDisposed` are stubbed because the real `RustOpaqueInterface`
// requires them but the test mock has no `Arc` to release.
class _FakeFfiNtsClient implements ffi.NtsClient {
  @override
  void clear() => RustLib.instance.api.crateApiNtsNtsClientClear(that: this);

  @override
  bool invalidate({required ffi.NtsServerSpec spec}) => RustLib.instance.api
      .crateApiNtsNtsClientInvalidate(that: this, spec: spec);

  @override
  ffi.TrustMode trustMode() =>
      RustLib.instance.api.crateApiNtsNtsClientTrustMode(that: this);

  @override
  Future<ffi.NtsTimeSample> query({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) => RustLib.instance.api.crateApiNtsNtsClientQuery(
    that: this,
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
  );

  @override
  Future<ffi.NtsWarmCookiesOutcome> warmCookies({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) => RustLib.instance.api.crateApiNtsNtsClientWarmCookies(
    that: this,
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
  );

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
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
  ffi.TrustBackend trustBackend = ffi.TrustBackend.platform,
}) => ffi.NtsTimeSample(
  utcUnixMicros: PlatformInt64Util.from(utcUnixMicros),
  roundTripMicros: PlatformInt64Util.from(roundTripMicros),
  serverStratum: serverStratum,
  aeadId: aeadId,
  freshCookies: freshCookies,
  phaseTimings: phaseTimings ?? _zeroFfiPhaseTimings(),
  trustBackend: trustBackend,
);

ffi.NtsWarmCookiesOutcome _ffiWarm(
  int cookies, {
  ffi.TrustBackend trustBackend = ffi.TrustBackend.platform,
}) => ffi.NtsWarmCookiesOutcome(
  freshCookies: cookies,
  phaseTimings: _zeroFfiPhaseTimings(),
  trustBackend: trustBackend,
);

ffi.NtsDnsPoolStats _zeroFfiDnsPoolStats() => ffi.NtsDnsPoolStats(
  inFlight: 0,
  highWaterMark: 0,
  recovered: BigInt.zero,
  refused: BigInt.zero,
);

ffi.NtsTrustStatus _zeroFfiTrustStatus() => ffi.NtsTrustStatus(
  androidPlatformInitSucceeded: false,
  androidHybridFallbackCount: BigInt.zero,
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
      api.nextWarm = _ffiWarm(8);
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
      const NtsError_Timeout c = NtsErrorTimeout(phase: TimeoutPhase.ntp);
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
          (
            const ffi.NtsError.network(message: 'eof'),
            const NtsError.network(message: 'eof'),
          ),
          (
            const ffi.NtsError.keProtocol(message: 'tls'),
            const NtsError.keProtocol(message: 'tls'),
          ),
          (
            const ffi.NtsError.ntpProtocol(message: 'kod'),
            const NtsError.ntpProtocol(message: 'kod'),
          ),
          (
            const ffi.NtsError.authentication(message: 'mac'),
            const NtsError.authentication(message: 'mac'),
          ),
          (
            const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.ntp),
            const NtsError.timeout(phase: TimeoutPhase.ntp),
          ),
          (
            const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.dnsSaturation),
            const NtsError.timeout(phase: TimeoutPhase.dnsSaturation),
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

    test('ntsWarmCookies also converts the FFI NtsError to its public '
        'twin', () async {
      // Symmetric coverage of the `ntsWarmCookies` catch arm. One
      // sample is sufficient because the conversion helper is shared
      // with `ntsQuery` (verified exhaustively by the case above);
      // this test pins the wrapper-level wiring on the warm path.
      api.nextThrow = const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.tls);
      await expectLater(
        ntsWarmCookies(spec: spec),
        throwsA(
          predicate<Object>(
            (e) =>
                e is NtsError &&
                e == const NtsError.timeout(phase: TimeoutPhase.tls),
          ),
        ),
      );
    });
  });

  group('public DTO value semantics', () {
    test('NtsServerSpec: ==, hashCode, toString', () {
      const a = NtsServerSpec(host: 'time.example', port: 4460);
      const b = NtsServerSpec(host: 'time.example', port: 4460);
      const differentHost = NtsServerSpec(host: 'time.other', port: 4460);
      const differentPort = NtsServerSpec(host: 'time.example', port: 4461);

      // Reflexive + value-based equality.
      expect(a, equals(a));
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);

      // Each field participates in equality.
      expect(a, isNot(equals(differentHost)));
      expect(a, isNot(equals(differentPort)));

      // Disjoint type comparison returns false rather than throwing.
      // The lint is suppressed because the disjoint check IS the
      // contract under test.
      // ignore: unrelated_type_equality_checks
      expect(a == 'time.example', isFalse);

      expect(a.toString(), 'NtsServerSpec(host: time.example, port: 4460)');
    });

    test('PhaseTimings: ==, hashCode, toString — every field counts', () {
      const base = PhaseTimings(
        dnsMicros: 11,
        connectMicros: 22,
        tlsHandshakeMicros: 33,
        keRecordIoMicros: 44,
      );
      const sameValue = PhaseTimings(
        dnsMicros: 11,
        connectMicros: 22,
        tlsHandshakeMicros: 33,
        keRecordIoMicros: 44,
      );
      expect(base, equals(sameValue));
      expect(base.hashCode, sameValue.hashCode);

      // Perturb one field at a time; each perturbation must break equality.
      const perturbations = <PhaseTimings>[
        PhaseTimings(
          dnsMicros: 99,
          connectMicros: 22,
          tlsHandshakeMicros: 33,
          keRecordIoMicros: 44,
        ),
        PhaseTimings(
          dnsMicros: 11,
          connectMicros: 99,
          tlsHandshakeMicros: 33,
          keRecordIoMicros: 44,
        ),
        PhaseTimings(
          dnsMicros: 11,
          connectMicros: 22,
          tlsHandshakeMicros: 99,
          keRecordIoMicros: 44,
        ),
        PhaseTimings(
          dnsMicros: 11,
          connectMicros: 22,
          tlsHandshakeMicros: 33,
          keRecordIoMicros: 99,
        ),
      ];
      for (final p in perturbations) {
        expect(base, isNot(equals(p)));
      }

      expect(
        base.toString(),
        'PhaseTimings(dnsMicros: 11, connectMicros: 22, '
        'tlsHandshakeMicros: 33, keRecordIoMicros: 44)',
      );
    });

    test('NtsTimeSample: ==, hashCode, toString — every field counts', () {
      const phase = PhaseTimings(
        dnsMicros: 1,
        connectMicros: 2,
        tlsHandshakeMicros: 3,
        keRecordIoMicros: 4,
      );
      const otherPhase = PhaseTimings(
        dnsMicros: 9,
        connectMicros: 2,
        tlsHandshakeMicros: 3,
        keRecordIoMicros: 4,
      );
      const base = NtsTimeSample(
        utcUnixMicros: 1_777_334_400_000_000,
        roundTripMicros: 12_500,
        serverStratum: 2,
        aeadId: 30,
        freshCookies: 7,
        phaseTimings: phase,
        trustBackend: TrustBackend.platform,
      );
      const sameValue = NtsTimeSample(
        utcUnixMicros: 1_777_334_400_000_000,
        roundTripMicros: 12_500,
        serverStratum: 2,
        aeadId: 30,
        freshCookies: 7,
        phaseTimings: phase,
        trustBackend: TrustBackend.platform,
      );
      expect(base, equals(sameValue));
      expect(base.hashCode, sameValue.hashCode);

      // One perturbation per field, including phaseTimings and trustBackend.
      const perturbations = <NtsTimeSample>[
        NtsTimeSample(
          utcUnixMicros: 0,
          roundTripMicros: 12_500,
          serverStratum: 2,
          aeadId: 30,
          freshCookies: 7,
          phaseTimings: phase,
          trustBackend: TrustBackend.platform,
        ),
        NtsTimeSample(
          utcUnixMicros: 1_777_334_400_000_000,
          roundTripMicros: 0,
          serverStratum: 2,
          aeadId: 30,
          freshCookies: 7,
          phaseTimings: phase,
          trustBackend: TrustBackend.platform,
        ),
        NtsTimeSample(
          utcUnixMicros: 1_777_334_400_000_000,
          roundTripMicros: 12_500,
          serverStratum: 99,
          aeadId: 30,
          freshCookies: 7,
          phaseTimings: phase,
          trustBackend: TrustBackend.platform,
        ),
        NtsTimeSample(
          utcUnixMicros: 1_777_334_400_000_000,
          roundTripMicros: 12_500,
          serverStratum: 2,
          aeadId: 15,
          freshCookies: 7,
          phaseTimings: phase,
          trustBackend: TrustBackend.platform,
        ),
        NtsTimeSample(
          utcUnixMicros: 1_777_334_400_000_000,
          roundTripMicros: 12_500,
          serverStratum: 2,
          aeadId: 30,
          freshCookies: 0,
          phaseTimings: phase,
          trustBackend: TrustBackend.platform,
        ),
        NtsTimeSample(
          utcUnixMicros: 1_777_334_400_000_000,
          roundTripMicros: 12_500,
          serverStratum: 2,
          aeadId: 30,
          freshCookies: 7,
          phaseTimings: otherPhase,
          trustBackend: TrustBackend.platform,
        ),
        NtsTimeSample(
          utcUnixMicros: 1_777_334_400_000_000,
          roundTripMicros: 12_500,
          serverStratum: 2,
          aeadId: 30,
          freshCookies: 7,
          phaseTimings: phase,
          trustBackend: TrustBackend.webpkiRoots,
        ),
      ];
      for (final p in perturbations) {
        expect(base, isNot(equals(p)));
      }

      expect(
        base.toString(),
        'NtsTimeSample(utcUnixMicros: 1777334400000000, '
        'roundTripMicros: 12500, serverStratum: 2, aeadId: 30, '
        'freshCookies: 7, phaseTimings: PhaseTimings(dnsMicros: 1, '
        'connectMicros: 2, tlsHandshakeMicros: 3, keRecordIoMicros: 4), '
        'trustBackend: platform)',
      );
    });

    test('NtsWarmCookiesOutcome: ==, hashCode, toString', () {
      const phase = PhaseTimings(
        dnsMicros: 1,
        connectMicros: 2,
        tlsHandshakeMicros: 3,
        keRecordIoMicros: 4,
      );
      const base = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: phase,
        trustBackend: TrustBackend.platform,
      );
      const sameValue = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: phase,
        trustBackend: TrustBackend.platform,
      );
      expect(base, equals(sameValue));
      expect(base.hashCode, sameValue.hashCode);

      // Each field participates in equality, including trustBackend.
      const differentCookies = NtsWarmCookiesOutcome(
        freshCookies: 9,
        phaseTimings: phase,
        trustBackend: TrustBackend.platform,
      );
      const differentPhase = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: PhaseTimings(
          dnsMicros: 99,
          connectMicros: 2,
          tlsHandshakeMicros: 3,
          keRecordIoMicros: 4,
        ),
        trustBackend: TrustBackend.platform,
      );
      const differentTrust = NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: phase,
        trustBackend: TrustBackend.webpkiRoots,
      );
      expect(base, isNot(equals(differentCookies)));
      expect(base, isNot(equals(differentPhase)));
      expect(base, isNot(equals(differentTrust)));

      expect(
        base.toString(),
        'NtsWarmCookiesOutcome(freshCookies: 8, '
        'phaseTimings: PhaseTimings(dnsMicros: 1, connectMicros: 2, '
        'tlsHandshakeMicros: 3, keRecordIoMicros: 4), '
        'trustBackend: platform)',
      );
    });

    test('NtsDnsPoolStats: ==, hashCode, toString — every field counts', () {
      // Note: BigInt is not const-constructible, so these are runtime
      // instances. The == / hashCode / toString contract still holds.
      final base = NtsDnsPoolStats(
        inFlight: 3,
        highWaterMark: 7,
        recovered: BigInt.from(42),
        refused: BigInt.from(2),
      );
      final sameValue = NtsDnsPoolStats(
        inFlight: 3,
        highWaterMark: 7,
        recovered: BigInt.from(42),
        refused: BigInt.from(2),
      );
      expect(base, equals(sameValue));
      expect(base.hashCode, sameValue.hashCode);

      final perturbations = <NtsDnsPoolStats>[
        NtsDnsPoolStats(
          inFlight: 99,
          highWaterMark: 7,
          recovered: BigInt.from(42),
          refused: BigInt.from(2),
        ),
        NtsDnsPoolStats(
          inFlight: 3,
          highWaterMark: 99,
          recovered: BigInt.from(42),
          refused: BigInt.from(2),
        ),
        NtsDnsPoolStats(
          inFlight: 3,
          highWaterMark: 7,
          recovered: BigInt.from(99),
          refused: BigInt.from(2),
        ),
        NtsDnsPoolStats(
          inFlight: 3,
          highWaterMark: 7,
          recovered: BigInt.from(42),
          refused: BigInt.from(99),
        ),
      ];
      for (final p in perturbations) {
        expect(base, isNot(equals(p)));
      }

      expect(
        base.toString(),
        'NtsDnsPoolStats(inFlight: 3, highWaterMark: 7, '
        'recovered: 42, refused: 2)',
      );
    });
  });

  group('NtsError variant semantics', () {
    // For each variant: factory builds the right subclass; ==/hashCode
    // are value-based; toString carries the payload (or the empty
    // parens for the payload-less NoCookies variant). String-payload
    // variants share a check shape and are exercised in a loop;
    // Timeout (TimeoutPhase payload) and NoCookies (no payload) are
    // checked separately.

    final stringPayloadCases = <(NtsError, NtsError, NtsError, Type, String)>[
      (
        const NtsError.invalidSpec('a'),
        const NtsError.invalidSpec('a'),
        const NtsError.invalidSpec('b'),
        NtsErrorInvalidSpec,
        'NtsError.invalidSpec(a)',
      ),
      (
        const NtsError.network(message: 'a'),
        const NtsError.network(message: 'a'),
        const NtsError.network(message: 'b'),
        NtsErrorNetwork,
        'NtsError.network(a)',
      ),
      (
        const NtsError.keProtocol(message: 'a'),
        const NtsError.keProtocol(message: 'a'),
        const NtsError.keProtocol(message: 'b'),
        NtsErrorKeProtocol,
        'NtsError.keProtocol(a)',
      ),
      (
        const NtsError.ntpProtocol(message: 'a'),
        const NtsError.ntpProtocol(message: 'a'),
        const NtsError.ntpProtocol(message: 'b'),
        NtsErrorNtpProtocol,
        'NtsError.ntpProtocol(a)',
      ),
      (
        const NtsError.authentication(message: 'a'),
        const NtsError.authentication(message: 'a'),
        const NtsError.authentication(message: 'b'),
        NtsErrorAuthentication,
        'NtsError.authentication(a)',
      ),
      (
        const NtsError.trustBackendUnavailable('a'),
        const NtsError.trustBackendUnavailable('a'),
        const NtsError.trustBackendUnavailable('b'),
        NtsErrorTrustBackendUnavailable,
        'NtsError.trustBackendUnavailable(a)',
      ),
      (
        const NtsError.internal('a'),
        const NtsError.internal('a'),
        const NtsError.internal('b'),
        NtsErrorInternal,
        'NtsError.internal(a)',
      ),
    ];

    test('string-payload variants: factory→subclass, ==, hashCode, '
        'toString', () {
      // Cross-variant inequality probe: a non-trivial NoCookies, used
      // to confirm every payload-bearing variant rejects an unrelated
      // shape rather than falling through to its `field0 == ...` arm.
      const otherVariant = NtsError.noCookies();
      for (final (a, sameValue, differentPayload, subclass, str)
          in stringPayloadCases) {
        expect(a, isA<NtsError>());
        expect(a.runtimeType, subclass);
        expect(a, isA<Exception>());
        expect(a, equals(a));
        expect(a, equals(sameValue));
        expect(a.hashCode, sameValue.hashCode);
        expect(a, isNot(equals(differentPayload)));
        expect(a, isNot(equals(otherVariant)));
        // Disjoint type — must not throw, must be false. The lint is
        // suppressed because the disjoint check IS the contract under
        // test.
        // ignore: unrelated_type_equality_checks
        expect(a == 'a', isFalse);
        expect(a.toString(), str);
      }
    });

    test('NtsError.timeout: factory→subclass, ==, hashCode, '
        'toString uses .name', () {
      const a = NtsError.timeout(phase: TimeoutPhase.ntp);
      const sameValue = NtsError.timeout(phase: TimeoutPhase.ntp);
      const differentPhase = NtsError.timeout(
        phase: TimeoutPhase.dnsSaturation,
      );

      expect(a.runtimeType, NtsErrorTimeout);
      expect(a, isA<NtsError>());
      expect(a, isA<Exception>());
      expect(a, equals(a));
      expect(a, equals(sameValue));
      expect(a.hashCode, sameValue.hashCode);
      expect(a, isNot(equals(differentPhase)));
      expect(a, isNot(equals(const NtsError.noCookies())));

      // toString uses the enum's `.name`, not its full type path.
      expect(a.toString(), 'NtsError.timeout(ntp)');
      expect(differentPhase.toString(), 'NtsError.timeout(dnsSaturation)');
    });

    test('NtsError.noCookies: factory→subclass, ==, hashCode, toString', () {
      const a = NtsError.noCookies();
      const b = NtsError.noCookies();

      expect(a.runtimeType, NtsErrorNoCookies);
      expect(a, isA<NtsError>());
      expect(a, isA<Exception>());

      // Two distinct instances of a payload-less variant compare equal
      // via the `other is X` branch (no payload to compare).
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);

      // Cross-variant inequality.
      expect(a, isNot(equals(const NtsError.network(message: 'x'))));
      // ignore: unrelated_type_equality_checks
      expect(a == 'noCookies', isFalse);

      expect(a.toString(), 'NtsError.noCookies()');
    });
  });

  group('NtsClient handle', () {
    const spec = NtsServerSpec(host: 'time.example', port: 4460);

    test('default constructor mints a fresh FFI handle each call', () {
      final c1 = NtsClient();
      final c2 = NtsClient();
      // The mock counts every `crateApiNtsNtsClientNew` invocation; one
      // per public `NtsClient()` call.
      expect(api.clientNewCalls, 2);
      // Pin the surface-level isolation invariant by routing one call
      // through each client and asserting the recorded `that:` handles
      // differ. The Rust-side per-instance `SessionTable` ownership is
      // exercised separately by the `cargo test --lib` cache-layer
      // suite; the wrapper's job is to forward through distinct
      // opaque handles.
      c1.invalidate(spec);
      final firstThat = api.lastClientInvalidateThat;
      c2.invalidate(spec);
      final secondThat = api.lastClientInvalidateThat;
      expect(firstThat, isNotNull);
      expect(secondThat, isNotNull);
      expect(identical(firstThat, secondThat), isFalse);
    });

    test('query forwards spec, defaults, and the FFI sample', () async {
      final client = NtsClient();
      final sample = await client.query(spec: spec);
      expect(api.lastClientQueryThat, isNotNull);
      expect(api.lastClientQueryTimeoutMs, kDefaultTimeoutMs);
      expect(api.lastClientQueryDnsCap, kDefaultDnsConcurrencyCap);
      // The wrapper converts the FFI sample to the public DTO; pin
      // both shape and value so a future conversion regression
      // surfaces here as well as in the top-level `ntsQuery` group.
      expect(sample, isA<NtsTimeSample>());
      expect(sample.utcUnixMicros, isA<int>());
    });

    test('query forwards explicit overrides verbatim', () async {
      final client = NtsClient();
      await client.query(spec: spec, timeoutMs: 1234, dnsConcurrencyCap: 32);
      expect(api.lastClientQueryTimeoutMs, 1234);
      expect(api.lastClientQueryDnsCap, 32);
    });

    test('warmCookies forwards spec, defaults, and the FFI outcome', () async {
      final client = NtsClient();
      api.nextWarm = _ffiWarm(7);
      final outcome = await client.warmCookies(spec: spec);
      expect(api.lastClientWarmThat, isNotNull);
      expect(api.lastClientWarmTimeoutMs, kDefaultTimeoutMs);
      expect(api.lastClientWarmDnsCap, kDefaultDnsConcurrencyCap);
      expect(outcome.freshCookies, 7);
    });

    test('warmCookies forwards explicit overrides verbatim', () async {
      final client = NtsClient();
      await client.warmCookies(
        spec: spec,
        timeoutMs: 9876,
        dnsConcurrencyCap: 8,
      );
      expect(api.lastClientWarmTimeoutMs, 9876);
      expect(api.lastClientWarmDnsCap, 8);
    });

    test('invalidate forwards the spec and returns the FFI bool', () {
      final client = NtsClient();
      api.nextInvalidateResult = true;
      expect(client.invalidate(spec), isTrue);
      expect(api.clientInvalidateCalls, 1);
      expect(api.lastClientInvalidateSpec?.host, spec.host);
      expect(api.lastClientInvalidateSpec?.port, spec.port);

      api.nextInvalidateResult = false;
      expect(client.invalidate(spec), isFalse);
      expect(api.clientInvalidateCalls, 2);
    });

    test('clear delegates to the FFI', () {
      final client = NtsClient();
      client.clear();
      expect(api.clientClearCalls, 1);
      expect(api.lastClientClearThat, isNotNull);
    });

    test(
      'query converts FFI NtsError to the public sealed class with stack',
      () async {
        final client = NtsClient();
        api.nextThrow = const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.tls);
        await expectLater(
          client.query(spec: spec),
          throwsA(
            isA<NtsError>().having(
              (e) => e,
              'is timeout(tls)',
              equals(const NtsError.timeout(phase: TimeoutPhase.tls)),
            ),
          ),
        );
      },
    );

    test(
      'warmCookies converts FFI NtsError to the public sealed class',
      () async {
        final client = NtsClient();
        api.nextThrow = const ffi.NtsError.noCookies();
        await expectLater(
          client.warmCookies(spec: spec),
          throwsA(
            isA<NtsError>().having(
              (e) => e,
              'is noCookies',
              equals(const NtsError.noCookies()),
            ),
          ),
        );
      },
    );

    test('default constructor routes through the FFI default factory', () {
      NtsClient();
      expect(api.clientNewCalls, 1);
      expect(api.clientWithTrustModeCalls, 0);
    });

    test(
      'trustMode override routes through withTrustMode for platformOnly',
      () {
        NtsClient(trustMode: TrustMode.platformOnly);
        // The wrapper short-circuits the explicit call when the caller
        // passed the default mode (covered by the previous test); a
        // non-default mode must round-trip through the FRB factory so
        // the Rust side observes the policy at construction time.
        expect(api.clientNewCalls, 0);
        expect(api.clientWithTrustModeCalls, 1);
        expect(api.lastClientWithTrustModeMode, ffi.TrustMode.platformOnly);
      },
    );

    test('trustMode override delegates to the default factory when '
        'platformWithFallback is requested', () {
      NtsClient(trustMode: TrustMode.platformWithFallback);
      // Equivalent to the no-arg form: avoids a redundant FFI hop
      // when the caller's mode matches the singleton's default.
      expect(api.clientNewCalls, 1);
      expect(api.clientWithTrustModeCalls, 0);
    });

    test('client.trustMode getter round-trips the construction choice', () {
      final c1 = NtsClient();
      final c2 = NtsClient(trustMode: TrustMode.platformOnly);
      expect(c1.trustMode, TrustMode.platformWithFallback);
      expect(c2.trustMode, TrustMode.platformOnly);
    });
  });

  group('ntsTrustStatus', () {
    test('forwards the FFI snapshot and converts every field', () {
      api.nextTrustStatus = ffi.NtsTrustStatus(
        defaultClientBackend: ffi.TrustBackend.platform,
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(7),
      );
      final status = ntsTrustStatus();
      expect(api.trustStatusCalls, 1);
      expect(status.defaultClientBackend, TrustBackend.platform);
      expect(status.androidPlatformInitSucceeded, isTrue);
      expect(status.androidHybridFallbackCount, BigInt.from(7));
    });

    test('null defaultClientBackend on the FFI side maps to null', () {
      api.nextTrustStatus = ffi.NtsTrustStatus(
        androidPlatformInitSucceeded: false,
        androidHybridFallbackCount: BigInt.zero,
      );
      final status = ntsTrustStatus();
      expect(status.defaultClientBackend, isNull);
      expect(status.androidPlatformInitSucceeded, isFalse);
      expect(status.androidHybridFallbackCount, BigInt.zero);
    });

    test(
      'every TrustBackend variant survives the FFI -> public conversion',
      () {
        for (final variant in const <(ffi.TrustBackend, TrustBackend)>[
          (ffi.TrustBackend.platform, TrustBackend.platform),
          (
            ffi.TrustBackend.platformWithHybridFallback,
            TrustBackend.platformWithHybridFallback,
          ),
          (ffi.TrustBackend.webpkiRoots, TrustBackend.webpkiRoots),
        ]) {
          api.nextTrustStatus = ffi.NtsTrustStatus(
            defaultClientBackend: variant.$1,
            androidPlatformInitSucceeded: false,
            androidHybridFallbackCount: BigInt.zero,
          );
          expect(ntsTrustStatus().defaultClientBackend, variant.$2);
        }
      },
    );
  });

  group('NtsTrustStatus DTO', () {
    test('==, hashCode, toString — every field counts', () {
      final base = NtsTrustStatus(
        defaultClientBackend: TrustBackend.platform,
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(3),
      );
      final sameValue = NtsTrustStatus(
        defaultClientBackend: TrustBackend.platform,
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(3),
      );
      expect(base, equals(sameValue));
      expect(base.hashCode, sameValue.hashCode);

      final perturbations = <NtsTrustStatus>[
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.webpkiRoots,
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          androidPlatformInitSucceeded: false,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(4),
        ),
        NtsTrustStatus(
          defaultClientBackend: null,
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
      ];
      for (final p in perturbations) {
        expect(base, isNot(equals(p)));
      }
      // Disjoint type — must not throw, must be false.
      // ignore: unrelated_type_equality_checks
      expect(base == 'NtsTrustStatus', isFalse);

      expect(
        base.toString(),
        'NtsTrustStatus(defaultClientBackend: platform, '
        'androidPlatformInitSucceeded: true, '
        'androidHybridFallbackCount: 3)',
      );
    });

    test(
      'toString renders null defaultClientBackend as the literal "null"',
      () {
        final unset = NtsTrustStatus(
          defaultClientBackend: null,
          androidPlatformInitSucceeded: false,
          androidHybridFallbackCount: BigInt.zero,
        );
        expect(
          unset.toString(),
          'NtsTrustStatus(defaultClientBackend: null, '
          'androidPlatformInitSucceeded: false, '
          'androidHybridFallbackCount: 0)',
        );
      },
    );
  });
}
