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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart';
import 'package:nts/src/ffi/api/nts.dart' as ffi;
import 'package:nts/src/ffi/frb_generated.dart';

class _RecordingApi implements NtsRustLibApi {
  int? lastQueryTimeoutMs;
  int? lastQueryDnsCap;
  int? lastQueryVerificationTimeMs;
  int? lastWarmTimeoutMs;
  int? lastWarmDnsCap;
  int? lastWarmVerificationTimeMs;
  int dnsPoolStatsCalls = 0;
  // Pinned FFI values returned by the mock. Tests assert that the
  // wrapper converts these into the matching public DTOs.
  ffi.NtsTimeSample nextSample = _ffiSample();
  ffi.NtsWarmCookiesOutcome nextWarm = _ffiWarm(0);
  ffi.NtsDnsPoolStats nextDnsPoolStats = _zeroFfiDnsPoolStats();
  Object? nextThrow;

  // Per-call query scripting for the `getTime` burst tests. When
  // non-null and non-empty, each query endpoint call (top-level and
  // per-client alike) consumes the head entry: an `ffi.NtsTimeSample`
  // is returned, anything else is thrown. Falls back to `nextThrow` /
  // `nextSample` when exhausted. `queryTimeouts` records the
  // `timeoutMs` each query call received, in dispatch order, so the
  // shared-budget tests can assert the deadline shrinks.
  List<Object>? queryScript;
  final List<int> queryTimeouts = [];

  // --- bridge-gate observation hooks --------------------------------
  //
  // `asyncGate`, when non-null, is awaited by all four async endpoint
  // mocks after they record their arguments, letting a test hold FFI
  // calls open to observe the public wrapper's bridge admission gate.
  // `asyncInFlight` / `asyncMaxInFlight` count how many of those mock
  // bodies are simultaneously open — i.e. how many calls the gate has
  // admitted — and `queryDispatches` counts `crateApiNtsNtsQuery`
  // entries so a test can assert a queued call never dispatched.
  Future<void> Function()? asyncGate;
  int asyncInFlight = 0;
  int asyncMaxInFlight = 0;
  int queryDispatches = 0;

  // Per-`NtsClient`-method recording. Distinct from the top-level
  // `lastQuery*` / `lastWarm*` fields above so a test that exercises
  // both surfaces can assert on each one independently. The `last*That`
  // fields hold the opaque `that:` handle the public wrapper passed
  // through, used by the isolation test to assert that two `NtsClient`
  // instances forward through distinct FFI handles.
  ffi.NtsClient? lastClientQueryThat;
  int? lastClientQueryTimeoutMs;
  int? lastClientQueryDnsCap;
  int? lastClientQueryVerificationTimeMs;
  ffi.NtsClient? lastClientWarmThat;
  int? lastClientWarmTimeoutMs;
  int? lastClientWarmDnsCap;
  int? lastClientWarmVerificationTimeMs;
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
    lastQueryVerificationTimeMs = null;
    lastWarmTimeoutMs = null;
    lastWarmDnsCap = null;
    lastWarmVerificationTimeMs = null;
    dnsPoolStatsCalls = 0;
    nextSample = _ffiSample();
    nextWarm = _ffiWarm(0);
    nextDnsPoolStats = _zeroFfiDnsPoolStats();
    nextThrow = null;
    queryScript = null;
    queryTimeouts.clear();
    asyncGate = null;
    asyncInFlight = 0;
    asyncMaxInFlight = 0;
    queryDispatches = 0;
    lastClientQueryThat = null;
    lastClientQueryTimeoutMs = null;
    lastClientQueryDnsCap = null;
    lastClientQueryVerificationTimeMs = null;
    lastClientWarmThat = null;
    lastClientWarmTimeoutMs = null;
    lastClientWarmDnsCap = null;
    lastClientWarmVerificationTimeMs = null;
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

  // Shared body for the four async endpoint mocks: bump the in-flight
  // gauges, optionally park on `asyncGate`, then produce `nextThrow` /
  // `result` exactly as the pre-gate mocks did. Scripted query calls
  // pass `honorNextThrow: false` so a consumed `queryScript` head is
  // authoritative and cannot be overridden by a stale `nextThrow`.
  Future<T> _asyncEndpoint<T>(
    T Function() result, {
    bool honorNextThrow = true,
  }) async {
    asyncInFlight++;
    if (asyncInFlight > asyncMaxInFlight) asyncMaxInFlight = asyncInFlight;
    try {
      final g = asyncGate;
      if (g != null) await g();
      if (honorNextThrow) {
        final t = nextThrow;
        if (t != null) throw t;
      }
      return result();
    } finally {
      asyncInFlight--;
    }
  }

  // Query-endpoint body shared by the top-level and per-client query
  // mocks: consumes the head of `queryScript` when present (sample =>
  // return, anything else => throw) — bypassing `nextThrow`, which the
  // script supersedes — otherwise defers to the plain `_asyncEndpoint`
  // path.
  Future<ffi.NtsTimeSample> _queryEndpoint() {
    final script = queryScript;
    if (script != null && script.isNotEmpty) {
      final head = script.removeAt(0);
      return _asyncEndpoint(honorNextThrow: false, () {
        if (head is ffi.NtsTimeSample) return head;
        throw head;
      });
    }
    return _asyncEndpoint(() => nextSample);
  }

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsQuery({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    queryDispatches++;
    lastQueryTimeoutMs = timeoutMs;
    lastQueryDnsCap = dnsConcurrencyCap;
    lastQueryVerificationTimeMs = verificationTimeMs;
    queryTimeouts.add(timeoutMs);
    return _queryEndpoint();
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsWarmCookies({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    lastWarmTimeoutMs = timeoutMs;
    lastWarmDnsCap = dnsConcurrencyCap;
    lastWarmVerificationTimeMs = verificationTimeMs;
    return _asyncEndpoint(() => nextWarm);
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
    clientTrustModes[fake] = const ffi.TrustMode.platformWithFallback();
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
      clientTrustModes[that] ?? const ffi.TrustMode.platformWithFallback();

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
    int? verificationTimeMs,
  }) {
    lastClientQueryThat = that;
    lastClientQueryTimeoutMs = timeoutMs;
    lastClientQueryDnsCap = dnsConcurrencyCap;
    lastClientQueryVerificationTimeMs = verificationTimeMs;
    queryTimeouts.add(timeoutMs);
    return _queryEndpoint();
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsClientWarmCookies({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    lastClientWarmThat = that;
    lastClientWarmTimeoutMs = timeoutMs;
    lastClientWarmDnsCap = dnsConcurrencyCap;
    lastClientWarmVerificationTimeMs = verificationTimeMs;
    return _asyncEndpoint(() => nextWarm);
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
// call back through `NtsRustLib.instance.api`, which is the same
// `_RecordingApi` instance, so the mock observes the call exactly as
// the real `NtsClientImpl` would have routed it. `dispose` /
// `isDisposed` are stubbed because the real `RustOpaqueInterface`
// requires them but the test mock has no `Arc` to release.
class _FakeFfiNtsClient implements ffi.NtsClient {
  @override
  void clear() => NtsRustLib.instance.api.crateApiNtsNtsClientClear(that: this);

  @override
  bool invalidate({required ffi.NtsServerSpec spec}) => NtsRustLib.instance.api
      .crateApiNtsNtsClientInvalidate(that: this, spec: spec);

  @override
  ffi.TrustMode trustMode() =>
      NtsRustLib.instance.api.crateApiNtsNtsClientTrustMode(that: this);

  @override
  Future<ffi.NtsTimeSample> query({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) => NtsRustLib.instance.api.crateApiNtsNtsClientQuery(
    that: this,
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
    verificationTimeMs: verificationTimeMs,
  );

  @override
  Future<ffi.NtsWarmCookiesOutcome> warmCookies({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) => NtsRustLib.instance.api.crateApiNtsNtsClientWarmCookies(
    that: this,
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
    verificationTimeMs: verificationTimeMs,
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
  defaultBackendPlatformCount: BigInt.zero,
  defaultBackendHybridCount: BigInt.zero,
  defaultBackendWebpkiCount: BigInt.zero,
  defaultBackendCustomCount: BigInt.zero,
  androidPlatformInitSucceeded: false,
  androidHybridFallbackCount: BigInt.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `NtsRustLib.initMock` rejects a second call within a single test process,
  // so the mock is wired exactly once and its recording state is cleared
  // between tests instead.
  final api = _RecordingApi();

  setUpAll(() {
    NtsRustLib.initMock(api: api);
  });

  setUp(api.reset);

  group('public API stability layer', () {
    const spec = NtsServerSpec(host: 'time.example', port: 4460);

    test('exported defaults expose the actual numeric values', () {
      // 4.0.0: `kDefaultDnsConcurrencyCap` is the actual numeric
      // default (4) rather than the pre-4.0.0 `0`-as-sentinel that
      // delegated to the Rust-side `DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS`.
      // The numeric value is the same default the Rust side would
      // have substituted, so callers using the constant by name see
      // no behaviour change. The wrapper now rejects literal `0` for
      // either u32 argument with `NtsError.invalidSpec`.
      //
      // Companion assertion: `defaults_match_dart_wrapper_constants`
      // in `rust/src/api/nts/tests.rs` pins the same numerics on the
      // Rust side. The pair catches cross-layer drift: a change to
      // either side without mirroring the other breaks the test on
      // the changed side. The two constants are NOT code-generated
      // from a single source of truth — keep them in sync by hand
      // when bumping the package's tuned defaults.
      expect(kDefaultTimeoutMs, 5000);
      expect(kDefaultDnsConcurrencyCap, 4);
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

    test(
      'ntsQuery defaults verificationTimeMs to null (system clock)',
      () async {
        await ntsQuery(spec: spec);
        expect(api.lastQueryVerificationTimeMs, isNull);
      },
    );

    test('ntsQuery forwards verificationTimeMs to the FFI boundary', () async {
      await ntsQuery(spec: spec, verificationTimeMs: 1_700_000_000_000);
      expect(api.lastQueryVerificationTimeMs, 1_700_000_000_000);
    });

    test('ntsQuery accepts verificationTimeMs == 0 (epoch) as valid', () async {
      await ntsQuery(spec: spec, verificationTimeMs: 0);
      expect(api.lastQueryVerificationTimeMs, 0);
    });

    test('ntsQuery rejects negative verificationTimeMs with '
        'NtsError.invalidSpec', () async {
      await expectLater(
        ntsQuery(spec: spec, verificationTimeMs: -1),
        throwsA(
          isA<NtsErrorInvalidSpec>().having(
            (e) => e.message,
            'message',
            contains('verificationTimeMs -1 is negative'),
          ),
        ),
      );
      // Rejected before any FFI dispatch.
      expect(api.lastQueryVerificationTimeMs, isNull);
      expect(api.lastQueryTimeoutMs, isNull);
    });

    test(
      'ntsQuery rejects port outside 1..65535 with NtsError.invalidSpec',
      () async {
        // Port=0 used to fall through to Rust's `port must be non-zero`
        // spec validator; from 4.0.0 the wrapper rejects it before any
        // FFI dispatch, so the returned Future completes with
        // NtsError.invalidSpec carrying a wrapper-authored message and
        // `api.lastQuery*` stay null. `expectLater` is awaited so the
        // assertion order is deterministic and the post-await
        // `api.lastQueryTimeoutMs` check happens after the rejected
        // Future has fully resolved -- not in parallel with it.
        await expectLater(
          ntsQuery(spec: const NtsServerSpec(host: 'h', port: 0)),
          throwsA(
            isA<NtsErrorInvalidSpec>().having(
              (e) => e.message,
              'message',
              contains('port 0 is outside the valid range 1..65535'),
            ),
          ),
        );
        await expectLater(
          ntsQuery(spec: const NtsServerSpec(host: 'h', port: 70000)),
          throwsA(isA<NtsErrorInvalidSpec>()),
        );
        expect(api.lastQueryTimeoutMs, isNull);
      },
    );

    test('ntsQuery rejects timeoutMs outside 1..0xFFFFFFFF with '
        'NtsError.invalidSpec', () async {
      await expectLater(
        ntsQuery(spec: spec, timeoutMs: 0),
        throwsA(
          isA<NtsErrorInvalidSpec>().having(
            (e) => e.message,
            'message',
            contains('timeoutMs 0 is outside the valid range'),
          ),
        ),
      );
      await expectLater(
        ntsQuery(spec: spec, timeoutMs: 0x1_0000_0000),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      expect(api.lastQueryTimeoutMs, isNull);
    });

    test('ntsQuery rejects dnsConcurrencyCap outside 1..0xFFFFFFFF with '
        'NtsError.invalidSpec', () async {
      await expectLater(
        ntsQuery(spec: spec, dnsConcurrencyCap: 0),
        throwsA(
          isA<NtsErrorInvalidSpec>().having(
            (e) => e.message,
            'message',
            contains('dnsConcurrencyCap 0 is outside the valid range'),
          ),
        ),
      );
      await expectLater(
        ntsQuery(spec: spec, dnsConcurrencyCap: 0x1_0000_0000),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      expect(api.lastQueryDnsCap, isNull);
    });

    test('ntsWarmCookies applies the same range validation', () async {
      await expectLater(
        ntsWarmCookies(spec: const NtsServerSpec(host: 'h', port: 0)),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      await expectLater(
        ntsWarmCookies(spec: spec, timeoutMs: -1),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      await expectLater(
        ntsWarmCookies(spec: spec, dnsConcurrencyCap: -5),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      expect(api.lastWarmTimeoutMs, isNull);
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

    test('ntsWarmCookies forwards verificationTimeMs and rejects '
        'negatives', () async {
      await ntsWarmCookies(spec: spec, verificationTimeMs: 1_700_000_000_000);
      expect(api.lastWarmVerificationTimeMs, 1_700_000_000_000);
      api.reset();
      await expectLater(
        ntsWarmCookies(spec: spec, verificationTimeMs: -5),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      expect(api.lastWarmVerificationTimeMs, isNull);
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
      // deprecated typedefs scheduled for removal at the next major
      // bump (see the typedef declarations in
      // `lib/src/api/errors.dart` and the `## 3.0.0` migration block
      // in `CHANGELOG.md`). The deprecation is intentional; the
      // lint suppression below is scoped to this single test so any
      // *real* use of the old names elsewhere in the package still
      // trips the warning.
      // ignore: deprecated_member_use_from_same_package
      const NtsError_InvalidSpec a = NtsErrorInvalidSpec(message: 'x');
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
            const NtsError.invalidSpec(message: 'bad'),
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
            const NtsError.internal(message: 'panic'),
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
        const NtsError.invalidSpec(message: 'a'),
        const NtsError.invalidSpec(message: 'a'),
        const NtsError.invalidSpec(message: 'b'),
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
        const NtsError.trustBackendUnavailable(message: 'a'),
        const NtsError.trustBackendUnavailable(message: 'a'),
        const NtsError.trustBackendUnavailable(message: 'b'),
        NtsErrorTrustBackendUnavailable,
        'NtsError.trustBackendUnavailable(a)',
      ),
      (
        const NtsError.internal(message: 'a'),
        const NtsError.internal(message: 'a'),
        const NtsError.internal(message: 'b'),
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

    test('non-null trustBackend: ==, hashCode, toString format, '
        'and round-trip through field accessors', () {
      // Pin the new attribution semantics introduced for nts-rqp:
      // every variant that grew the optional `trustBackend` field
      // must (a) participate in equality / hashCode against an
      // identical instance, (b) reject an otherwise-identical
      // instance whose backend differs, and (c) render as
      // `NtsError.<variant>(<payload>, backend: <name>)` in
      // `toString` so log scrapers can pull the attribution back
      // off the formatted line.
      const network = NtsError.network(
        message: 'eof',
        trustBackend: TrustBackend.platformWithHybridFallback,
      );
      const networkSame = NtsError.network(
        message: 'eof',
        trustBackend: TrustBackend.platformWithHybridFallback,
      );
      const networkOtherBackend = NtsError.network(
        message: 'eof',
        trustBackend: TrustBackend.platform,
      );
      const networkNullBackend = NtsError.network(message: 'eof');

      expect(network, equals(networkSame));
      expect(network.hashCode, networkSame.hashCode);
      expect(network, isNot(equals(networkOtherBackend)));
      expect(network, isNot(equals(networkNullBackend)));
      expect(
        network.toString(),
        'NtsError.network(eof, backend: platformWithHybridFallback)',
      );
      // Field accessors expose the backend on the variant subclass.
      expect(
        (network as NtsErrorNetwork).trustBackend,
        TrustBackend.platformWithHybridFallback,
      );
      expect((networkNullBackend as NtsErrorNetwork).trustBackend, isNull);

      // Timeout is the second variant that gained the field; cover
      // it explicitly because it carries `phase` rather than
      // `message`, so the toString format differs.
      const timeout = NtsError.timeout(
        phase: TimeoutPhase.keRecordIo,
        trustBackend: TrustBackend.webpkiRoots,
      );
      const timeoutSame = NtsError.timeout(
        phase: TimeoutPhase.keRecordIo,
        trustBackend: TrustBackend.webpkiRoots,
      );
      const timeoutOtherBackend = NtsError.timeout(
        phase: TimeoutPhase.keRecordIo,
        trustBackend: TrustBackend.platform,
      );
      expect(timeout, equals(timeoutSame));
      expect(timeout.hashCode, timeoutSame.hashCode);
      expect(timeout, isNot(equals(timeoutOtherBackend)));
      expect(
        timeout.toString(),
        'NtsError.timeout(keRecordIo, backend: webpkiRoots)',
      );
      expect(
        (timeout as NtsErrorTimeout).trustBackend,
        TrustBackend.webpkiRoots,
      );

      // NoCookies has no other payload, so the toString reduces to
      // just the backend tag when it is set.
      const noCookies = NtsError.noCookies(trustBackend: TrustBackend.platform);
      expect(noCookies.toString(), 'NtsError.noCookies(backend: platform)');
      expect(
        (noCookies as NtsErrorNoCookies).trustBackend,
        TrustBackend.platform,
      );
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

    test('query forwards verificationTimeMs and rejects negatives', () async {
      final client = NtsClient();
      await client.query(spec: spec, verificationTimeMs: 1_700_000_000_000);
      expect(api.lastClientQueryVerificationTimeMs, 1_700_000_000_000);
      api.reset();
      await expectLater(
        client.query(spec: spec, verificationTimeMs: -1),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      expect(api.lastClientQueryVerificationTimeMs, isNull);
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

    test('warmCookies forwards verificationTimeMs and rejects '
        'negatives', () async {
      final client = NtsClient();
      await client.warmCookies(
        spec: spec,
        verificationTimeMs: 1_700_000_000_000,
      );
      expect(api.lastClientWarmVerificationTimeMs, 1_700_000_000_000);
      api.reset();
      await expectLater(
        client.warmCookies(spec: spec, verificationTimeMs: -1),
        throwsA(isA<NtsErrorInvalidSpec>()),
      );
      expect(api.lastClientWarmVerificationTimeMs, isNull);
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

    test(
      'invalidate rejects port outside 1..65535 with NtsError.invalidSpec',
      () {
        // Wrapper-side range validation matches the surface PR #34
        // gave the four async wrappers; out-of-range ports throw
        // NtsError.invalidSpec from the wrapper before reaching the
        // FRB u16 encoder, so `api.lastClientInvalidate*` stay null
        // and `api.clientInvalidateCalls` does not advance.
        final client = NtsClient();
        final invalidatesBefore = api.clientInvalidateCalls;
        expect(
          () => client.invalidate(const NtsServerSpec(host: 'h', port: 0)),
          throwsA(
            isA<NtsErrorInvalidSpec>().having(
              (e) => e.message,
              'message',
              contains('port 0 is outside the valid range 1..65535'),
            ),
          ),
        );
        expect(
          () => client.invalidate(const NtsServerSpec(host: 'h', port: 70000)),
          throwsA(
            isA<NtsErrorInvalidSpec>().having(
              (e) => e.message,
              'message',
              contains('port 70000 is outside the valid range 1..65535'),
            ),
          ),
        );
        expect(api.clientInvalidateCalls, invalidatesBefore);
        expect(api.lastClientInvalidateSpec, isNull);
      },
    );

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
        expect(
          api.lastClientWithTrustModeMode,
          const ffi.TrustMode.platformOnly(),
        );
      },
    );

    test('trustMode override routes through withTrustMode for bundledOnly', () {
      NtsClient(trustMode: TrustMode.bundledOnly);
      expect(api.clientNewCalls, 0);
      expect(api.clientWithTrustModeCalls, 1);
      expect(
        api.lastClientWithTrustModeMode,
        const ffi.TrustMode.bundledOnly(),
      );
    });

    test('trustMode override routes through withTrustMode for custom', () {
      final roots = [1, 2, 3];
      NtsClient(trustMode: TrustMode.custom, customRoots: roots);
      expect(api.clientNewCalls, 0);
      expect(api.clientWithTrustModeCalls, 1);
      expect(
        api.lastClientWithTrustModeMode,
        ffi.TrustMode.custom(Uint8List.fromList(roots)),
      );
    });

    test(
      'trustMode validation throws ArgumentError on mismatched arguments',
      () {
        expect(
          () => NtsClient(
            trustMode: TrustMode.platformOnly,
            customRoots: [1, 2, 3],
          ),
          throwsArgumentError,
        );
        expect(
          () => NtsClient(trustMode: TrustMode.custom, customRoots: null),
          throwsArgumentError,
        );
        expect(
          () => NtsClient(trustMode: TrustMode.custom, customRoots: []),
          throwsArgumentError,
        );
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
      final c3 = NtsClient(trustMode: TrustMode.bundledOnly);
      final c4 = NtsClient(trustMode: TrustMode.custom, customRoots: [1, 2, 3]);
      expect(c1.trustMode, TrustMode.platformWithFallback);
      expect(c2.trustMode, TrustMode.platformOnly);
      expect(c3.trustMode, TrustMode.bundledOnly);
      expect(c4.trustMode, TrustMode.custom);
    });
  });

  group('ntsTrustStatus', () {
    test('forwards the FFI snapshot and converts every field', () {
      api.nextTrustStatus = ffi.NtsTrustStatus(
        defaultClientBackend: ffi.TrustBackend.platform,
        defaultBackendPlatformCount: BigInt.from(11),
        defaultBackendHybridCount: BigInt.from(2),
        defaultBackendWebpkiCount: BigInt.from(5),
        defaultBackendCustomCount: BigInt.from(9),
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(7),
      );
      final status = ntsTrustStatus();
      expect(api.trustStatusCalls, 1);
      expect(status.defaultClientBackend, TrustBackend.platform);
      expect(status.defaultBackendPlatformCount, BigInt.from(11));
      expect(status.defaultBackendHybridCount, BigInt.from(2));
      expect(status.defaultBackendWebpkiCount, BigInt.from(5));
      expect(status.defaultBackendCustomCount, BigInt.from(9));
      expect(status.androidPlatformInitSucceeded, isTrue);
      expect(status.androidHybridFallbackCount, BigInt.from(7));
    });

    test('null defaultClientBackend on the FFI side maps to null', () {
      api.nextTrustStatus = ffi.NtsTrustStatus(
        defaultBackendPlatformCount: BigInt.zero,
        defaultBackendHybridCount: BigInt.zero,
        defaultBackendWebpkiCount: BigInt.zero,
        defaultBackendCustomCount: BigInt.zero,
        androidPlatformInitSucceeded: false,
        androidHybridFallbackCount: BigInt.zero,
      );
      final status = ntsTrustStatus();
      expect(status.defaultClientBackend, isNull);
      expect(status.defaultBackendPlatformCount, BigInt.zero);
      expect(status.defaultBackendHybridCount, BigInt.zero);
      expect(status.defaultBackendWebpkiCount, BigInt.zero);
      expect(status.defaultBackendCustomCount, BigInt.zero);
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
          (ffi.TrustBackend.custom, TrustBackend.custom),
        ]) {
          api.nextTrustStatus = ffi.NtsTrustStatus(
            defaultClientBackend: variant.$1,
            defaultBackendPlatformCount: BigInt.zero,
            defaultBackendHybridCount: BigInt.zero,
            defaultBackendWebpkiCount: BigInt.zero,
            defaultBackendCustomCount: BigInt.zero,
            androidPlatformInitSucceeded: false,
            androidHybridFallbackCount: BigInt.zero,
          );
          expect(ntsTrustStatus().defaultClientBackend, variant.$2);
        }
      },
    );

    test('per-backend counters round-trip through the FFI -> public layer', () {
      // Counter values chosen to be mutually distinct so an off-by-one
      // wiring error (platform → hybrid swap, etc.) on either side of
      // the FFI boundary fails this assertion rather than silently
      // landing on a coincidentally-equal value.
      api.nextTrustStatus = ffi.NtsTrustStatus(
        defaultClientBackend: ffi.TrustBackend.platformWithHybridFallback,
        defaultBackendPlatformCount: BigInt.from(13),
        defaultBackendHybridCount: BigInt.from(17),
        defaultBackendWebpkiCount: BigInt.from(19),
        defaultBackendCustomCount: BigInt.from(29),
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(23),
      );
      final status = ntsTrustStatus();
      expect(status.defaultBackendPlatformCount, BigInt.from(13));
      expect(status.defaultBackendHybridCount, BigInt.from(17));
      expect(status.defaultBackendWebpkiCount, BigInt.from(19));
      expect(status.defaultBackendCustomCount, BigInt.from(29));
    });
  });

  group('NtsTrustStatus DTO', () {
    test('==, hashCode, toString — every field counts', () {
      final base = NtsTrustStatus(
        defaultClientBackend: TrustBackend.platform,
        defaultBackendPlatformCount: BigInt.from(11),
        defaultBackendHybridCount: BigInt.from(2),
        defaultBackendWebpkiCount: BigInt.from(5),
        defaultBackendCustomCount: BigInt.from(9),
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(3),
      );
      final sameValue = NtsTrustStatus(
        defaultClientBackend: TrustBackend.platform,
        defaultBackendPlatformCount: BigInt.from(11),
        defaultBackendHybridCount: BigInt.from(2),
        defaultBackendWebpkiCount: BigInt.from(5),
        defaultBackendCustomCount: BigInt.from(9),
        androidPlatformInitSucceeded: true,
        androidHybridFallbackCount: BigInt.from(3),
      );
      expect(base, equals(sameValue));
      expect(base.hashCode, sameValue.hashCode);

      // Perturb each independent dimension in turn so a regression
      // that drops one field from `==` / `hashCode` shows up here as
      // a value-equality assertion failure on that specific
      // perturbation rather than a uniform false positive.
      final perturbations = <NtsTrustStatus>[
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.webpkiRoots,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(9),
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          defaultBackendPlatformCount: BigInt.from(12),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(9),
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(3),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(9),
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(6),
          defaultBackendCustomCount: BigInt.from(9),
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(10),
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(9),
          androidPlatformInitSucceeded: false,
          androidHybridFallbackCount: BigInt.from(3),
        ),
        NtsTrustStatus(
          defaultClientBackend: TrustBackend.platform,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(9),
          androidPlatformInitSucceeded: true,
          androidHybridFallbackCount: BigInt.from(4),
        ),
        NtsTrustStatus(
          defaultClientBackend: null,
          defaultBackendPlatformCount: BigInt.from(11),
          defaultBackendHybridCount: BigInt.from(2),
          defaultBackendWebpkiCount: BigInt.from(5),
          defaultBackendCustomCount: BigInt.from(9),
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
        'defaultBackendPlatformCount: 11, '
        'defaultBackendHybridCount: 2, '
        'defaultBackendWebpkiCount: 5, '
        'defaultBackendCustomCount: 9, '
        'androidPlatformInitSucceeded: true, '
        'androidHybridFallbackCount: 3)',
      );
    });

    test(
      'toString renders null defaultClientBackend as the literal "null"',
      () {
        final unset = NtsTrustStatus(
          defaultClientBackend: null,
          defaultBackendPlatformCount: BigInt.zero,
          defaultBackendHybridCount: BigInt.zero,
          defaultBackendWebpkiCount: BigInt.zero,
          defaultBackendCustomCount: BigInt.zero,
          androidPlatformInitSucceeded: false,
          androidHybridFallbackCount: BigInt.zero,
        );
        expect(
          unset.toString(),
          'NtsTrustStatus(defaultClientBackend: null, '
          'defaultBackendPlatformCount: 0, '
          'defaultBackendHybridCount: 0, '
          'defaultBackendWebpkiCount: 0, '
          'defaultBackendCustomCount: 0, '
          'androidPlatformInitSucceeded: false, '
          'androidHybridFallbackCount: 0)',
        );
      },
    );
  });

  group('getTime convenience layer', () {
    const spec = NtsServerSpec(host: 'time.example', port: 4460);

    test('warm + burst happy path picks the lowest-RTT sample and '
        'applies roundTrip/2 compensation', () async {
      api.nextWarm = _ffiWarm(8);
      api.queryScript = [
        _ffiSample(utcUnixMicros: 1_000_000, roundTripMicros: 9000),
        _ffiSample(
          utcUnixMicros: 2_000_000,
          roundTripMicros: 4000,
          trustBackend: ffi.TrustBackend.webpkiRoots,
        ),
        _ffiSample(utcUnixMicros: 3_000_000, roundTripMicros: 7000),
        _ffiSample(utcUnixMicros: 4_000_000, roundTripMicros: 6000),
      ];
      final synced = await ntsGetTime(spec: spec);
      // Default profile is mobile: maxBurst 4, all four script
      // entries consumed.
      expect(api.queryDispatches, 4);
      // `utcUnixMicros` is the compensated winning sample plus the
      // anchor-lag advance covering the two queries that ran after
      // it. The mocks complete in microseconds, so bound the lag
      // rather than pin an exact instant.
      expect(synced.utcUnixMicros, greaterThanOrEqualTo(2_000_000 + 2000));
      expect(synced.utcUnixMicros, lessThan(2_000_000 + 2000 + 1_000_000));
      expect(synced.roundTripMicros, 4000);
      expect(synced.samplesUsed, 4);
      expect(synced.trustBackend, TrustBackend.webpkiRoots);
    });

    test('the compensated UTC is advanced across the burst time that '
        'elapses after the winning sample arrives', () async {
      api.nextWarm = _ffiWarm(8);
      // Every endpoint mock (warm + each query) parks 40ms on the
      // gate. The winning (lowest-RTT) sample is the *first* query,
      // so the three remaining gated queries put >= 120ms between the
      // winning recv and NtsSyncedTime construction — the anchor-lag
      // advance must surface in utcUnixMicros.
      api.asyncGate = () =>
          Future<void>.delayed(const Duration(milliseconds: 40));
      api.queryScript = [
        _ffiSample(utcUnixMicros: 1_000_000, roundTripMicros: 2000),
        _ffiSample(utcUnixMicros: 2_000_000, roundTripMicros: 9000),
        _ffiSample(utcUnixMicros: 3_000_000, roundTripMicros: 8000),
        _ffiSample(utcUnixMicros: 4_000_000, roundTripMicros: 7000),
      ];
      final synced = await ntsGetTime(spec: spec);
      expect(api.queryDispatches, 4);
      expect(synced.roundTripMicros, 2000);
      // Compensated base (1_000_000 + 1000) advanced by at least the
      // three post-winner gate delays; upper bound stays loose to be
      // timer-slop-proof.
      expect(
        synced.utcUnixMicros,
        greaterThanOrEqualTo(1_000_000 + 1000 + 120_000),
      );
      expect(synced.utcUnixMicros, lessThan(1_000_000 + 1000 + 5_000_000));
    });

    test('burst size is clamped to the handshake cookie count', () async {
      api.nextWarm = _ffiWarm(2);
      await ntsGetTime(spec: spec);
      expect(api.queryDispatches, 2);
    });

    test('profile knobs are forwarded to the warm and every burst '
        'query', () async {
      api.nextWarm = _ffiWarm(8);
      const profile = NtsProfile(
        maxBurst: 2,
        timeoutMs: 7000,
        dnsConcurrencyCap: 6,
        bridgeConcurrencyCap: 3,
      );
      await ntsGetTime(spec: spec, profile: profile, verificationTimeMs: 42);
      // The warm draws from the shared budget, so the forwarded
      // deadline is the profile's timeoutMs minus the (tiny, ceilinged)
      // pre-warm overhead.
      expect(api.lastWarmTimeoutMs, inInclusiveRange(6900, 7000));
      expect(api.lastWarmDnsCap, 6);
      expect(api.lastWarmVerificationTimeMs, 42);
      expect(api.queryDispatches, 2);
      expect(api.lastQueryDnsCap, 6);
      expect(api.lastQueryVerificationTimeMs, 42);
    });

    test('warm and burst draw down one shared total budget', () async {
      api.nextWarm = _ffiWarm(8);
      await ntsGetTime(spec: spec);
      // The warm gets the remaining balance (the whole budget minus
      // the ceilinged pre-warm overhead); each query gets only what
      // is left, so no forwarded deadline may exceed its predecessor.
      final warmTimeout = api.lastWarmTimeoutMs!;
      expect(
        warmTimeout,
        inInclusiveRange(
          NtsProfile.mobile.timeoutMs - 100,
          NtsProfile.mobile.timeoutMs,
        ),
      );
      expect(api.queryTimeouts, hasLength(4));
      var previous = warmTimeout;
      for (final t in api.queryTimeouts) {
        expect(t, lessThanOrEqualTo(previous));
        previous = t;
      }
    });

    test('individual burst failures are tolerated when at least one '
        'sample lands', () async {
      api.nextWarm = _ffiWarm(8);
      api.queryScript = [
        const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.ntp),
        _ffiSample(utcUnixMicros: 5_000_000, roundTripMicros: 2000),
        const ffi.NtsError.network(message: 'eof'),
        const ffi.NtsError.network(message: 'eof again'),
      ];
      final synced = await ntsGetTime(spec: spec);
      expect(synced.samplesUsed, 1);
      // Compensated sample plus a bounded anchor-lag advance for the
      // two failing queries that ran after it.
      expect(synced.utcUnixMicros, greaterThanOrEqualTo(5_000_000 + 1000));
      expect(synced.utcUnixMicros, lessThan(5_000_000 + 1000 + 1_000_000));
      expect(api.queryDispatches, 4);
    });

    test('an all-fail burst rethrows the last query error as its '
        'public twin', () async {
      api.nextWarm = _ffiWarm(8);
      api.queryScript = [
        const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.ntp),
        const ffi.NtsError.network(message: 'first'),
        const ffi.NtsError.network(message: 'second'),
        const ffi.NtsError.authentication(message: 'mac stripped'),
      ];
      await expectLater(
        ntsGetTime(spec: spec),
        throwsA(
          predicate<Object>(
            (e) =>
                e is NtsError &&
                e == const NtsError.authentication(message: 'mac stripped'),
          ),
        ),
      );
      expect(api.queryDispatches, 4);
    });

    test('a warm failure propagates as-is and dispatches no '
        'queries', () async {
      api.nextThrow = const ffi.NtsError.timeout(phase: ffi.TimeoutPhase.tls);
      await expectLater(
        ntsGetTime(spec: spec),
        throwsA(
          predicate<Object>(
            (e) =>
                e is NtsError &&
                e == const NtsError.timeout(phase: TimeoutPhase.tls),
          ),
        ),
      );
      expect(api.queryDispatches, 0);
    });

    test('a zero-cookie handshake fails with noCookies before any '
        'query', () async {
      api.nextWarm = _ffiWarm(0, trustBackend: ffi.TrustBackend.custom);
      await expectLater(
        ntsGetTime(spec: spec),
        throwsA(
          isA<NtsErrorNoCookies>().having(
            (e) => e.trustBackend,
            'trustBackend',
            TrustBackend.custom,
          ),
        ),
      );
      expect(api.queryDispatches, 0);
    });

    test('budget exhausted by the warm surfaces as timeout(ntp)', () async {
      api.nextWarm = _ffiWarm(8);
      api.asyncGate = () =>
          Future<void>.delayed(const Duration(milliseconds: 60));
      const profile = NtsProfile(
        maxBurst: 3,
        timeoutMs: 20,
        dnsConcurrencyCap: 4,
        bridgeConcurrencyCap: 4,
      );
      await expectLater(
        ntsGetTime(spec: spec, profile: profile),
        throwsA(
          isA<NtsErrorTimeout>()
              .having((e) => e.phase, 'phase', TimeoutPhase.ntp)
              .having(
                (e) => e.trustBackend,
                'trustBackend',
                TrustBackend.platform,
              ),
        ),
      );
      // The warm completed (late); no query was ever dispatched.
      expect(api.queryDispatches, 0);
    });

    test('out-of-range maxBurst is rejected before any FFI dispatch on '
        'both entry points', () async {
      const belowFloor = NtsProfile(
        maxBurst: 0,
        timeoutMs: 5000,
        dnsConcurrencyCap: 4,
        bridgeConcurrencyCap: 4,
      );
      const aboveCeiling = NtsProfile(
        maxBurst: 0x100000000, // u32::MAX + 1
        timeoutMs: 5000,
        dnsConcurrencyCap: 4,
        bridgeConcurrencyCap: 4,
      );
      final client = NtsClient();
      for (final broken in [belowFloor, aboveCeiling]) {
        for (final mint in <Future<Object?> Function()>[
          () => ntsGetTime(spec: spec, profile: broken),
          () => client.getTime(spec: spec, profile: broken),
        ]) {
          await expectLater(
            mint(),
            throwsA(
              isA<NtsErrorInvalidSpec>().having(
                (e) => e.message,
                'message',
                contains('maxBurst'),
              ),
            ),
          );
        }
      }
      expect(api.lastWarmTimeoutMs, isNull);
      expect(api.lastClientWarmTimeoutMs, isNull);
      expect(api.queryDispatches, 0);
    });

    test('out-of-range profile fields are rejected on the same terms '
        'as ntsQuery', () async {
      const broken = NtsProfile(
        maxBurst: 3,
        timeoutMs: 0,
        dnsConcurrencyCap: 4,
        bridgeConcurrencyCap: 4,
      );
      await expectLater(
        ntsGetTime(spec: spec, profile: broken),
        throwsA(
          isA<NtsErrorInvalidSpec>().having(
            (e) => e.message,
            'message',
            contains('timeoutMs'),
          ),
        ),
      );
      expect(api.lastWarmTimeoutMs, isNull);
    });

    test('NtsClient.getTime routes through the client endpoints and '
        'leaves the default client untouched', () async {
      api.nextWarm = _ffiWarm(8);
      final client = NtsClient();
      final synced = await client.getTime(spec: spec);
      expect(synced.samplesUsed, 4);
      expect(api.lastClientWarmThat, isNotNull);
      expect(api.lastClientQueryThat, same(api.lastClientWarmThat));
      // Top-level endpoints never fired.
      expect(api.lastWarmTimeoutMs, isNull);
      expect(api.lastQueryTimeoutMs, isNull);
    });
  });

  group('NtsProfile / NtsSyncedTime models', () {
    test('presets carry the documented values', () {
      expect(NtsProfile.mobile.maxBurst, 4);
      expect(NtsProfile.mobile.timeoutMs, 6000);
      expect(NtsProfile.mobile.dnsConcurrencyCap, 4);
      expect(NtsProfile.mobile.bridgeConcurrencyCap, 4);
      expect(NtsProfile.desktop.maxBurst, 8);
      expect(NtsProfile.desktop.timeoutMs, 7000);
      expect(NtsProfile.desktop.dnsConcurrencyCap, 8);
      expect(NtsProfile.desktop.bridgeConcurrencyCap, 8);
      expect(NtsProfile.embedded.maxBurst, 2);
      expect(NtsProfile.embedded.timeoutMs, 10000);
      expect(NtsProfile.embedded.dnsConcurrencyCap, 2);
      expect(NtsProfile.embedded.bridgeConcurrencyCap, 2);
    });

    test('NtsProfile equality and hashCode are value-based', () {
      const a = NtsProfile(
        maxBurst: 4,
        timeoutMs: 6000,
        dnsConcurrencyCap: 4,
        bridgeConcurrencyCap: 4,
      );
      expect(a, NtsProfile.mobile);
      expect(a.hashCode, NtsProfile.mobile.hashCode);
      expect(a, isNot(NtsProfile.desktop));
      expect(
        a.toString(),
        'NtsProfile(maxBurst: 4, timeoutMs: 6000, '
        'dnsConcurrencyCap: 4, bridgeConcurrencyCap: 4)',
      );
    });

    test('NtsSyncedTime projects utcNow via its monotonic anchor', () async {
      final synced = NtsSyncedTime(
        utcUnixMicros: 1_700_000_000_000_000,
        roundTripMicros: 4000,
        samplesUsed: 2,
        trustBackend: TrustBackend.platform,
      );
      final first = synced.utcNow;
      expect(first.isUtc, isTrue);
      expect(
        first.microsecondsSinceEpoch,
        greaterThanOrEqualTo(1_700_000_000_000_000),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = synced.utcNow;
      // Monotonic projection: time moved forward by at least the
      // sleep (modulo timer slop, hence the loose lower bound).
      expect(second.isAfter(first), isTrue);
      expect(synced.elapsedSinceSync, greaterThan(Duration.zero));
    });

    test('NtsSyncedTime toString carries the diagnostic fields', () {
      final synced = NtsSyncedTime(
        utcUnixMicros: 123,
        roundTripMicros: 456,
        samplesUsed: 2,
        trustBackend: TrustBackend.platformWithHybridFallback,
      );
      expect(
        synced.toString(),
        allOf(
          contains('utcUnixMicros: 123'),
          contains('roundTripMicros: 456'),
          contains('samplesUsed: 2'),
          contains('trustBackend: platformWithHybridFallback'),
        ),
      );
    });
  });

  group('bridge admission gate', () {
    const spec = NtsServerSpec(host: 'time.example', port: 4460);

    // The gate's `_bridgeInFlight` / `_bridgeQueue` state is
    // isolate-local and shared by every test in this suite's isolate,
    // so every test below drains all its futures before returning; a
    // leaked slot would silently shrink the cap for whichever test
    // runs next.

    test('exported default exposes the actual numeric value', () {
      expect(kDefaultBridgeConcurrencyCap, 4);
    });

    test('rejects bridgeConcurrencyCap outside 1..0xFFFFFFFF with '
        'NtsError.invalidSpec on all four wrappers', () async {
      final client = NtsClient();
      // Each rejected future is minted inside its own `expectLater`
      // so a listener is attached before the next event-loop turn —
      // a batch of pre-created failed futures would surface as
      // unhandled async errors while the first one is awaited.
      // Both invalid values (below-range 0 and above-range 2^32) are
      // exercised on every wrapper, so a wrapper that skipped either
      // bound check would fail this test.
      final rejected = <Future<Object?> Function()>[
        () => ntsQuery(spec: spec, bridgeConcurrencyCap: 0),
        () => ntsQuery(spec: spec, bridgeConcurrencyCap: 0x1_0000_0000),
        () => ntsWarmCookies(spec: spec, bridgeConcurrencyCap: 0),
        () => ntsWarmCookies(spec: spec, bridgeConcurrencyCap: 0x1_0000_0000),
        () => client.query(spec: spec, bridgeConcurrencyCap: 0),
        () => client.query(spec: spec, bridgeConcurrencyCap: 0x1_0000_0000),
        () => client.warmCookies(spec: spec, bridgeConcurrencyCap: 0),
        () =>
            client.warmCookies(spec: spec, bridgeConcurrencyCap: 0x1_0000_0000),
      ];
      for (final mint in rejected) {
        await expectLater(
          mint(),
          throwsA(
            isA<NtsErrorInvalidSpec>().having(
              (e) => e.message,
              'message',
              contains('bridgeConcurrencyCap'),
            ),
          ),
        );
      }
      // All eight rejected before any FFI dispatch.
      expect(api.queryDispatches, 0);
      expect(api.lastWarmTimeoutMs, isNull);
      expect(api.lastClientQueryTimeoutMs, isNull);
      expect(api.lastClientWarmTimeoutMs, isNull);
    });

    test('uncontended calls forward timeoutMs verbatim', () async {
      // The queue-wait deduction must not apply to calls that never
      // queued: bit-for-bit forwarding is the pre-gate behaviour.
      await ntsQuery(spec: spec, timeoutMs: 1234);
      expect(api.lastQueryTimeoutMs, 1234);
    });

    test('default cap admits at most 4 concurrent dispatches', () async {
      final gate = Completer<void>();
      api.asyncGate = () => gate.future;
      final futures = <Future<NtsTimeSample>>[
        for (var i = 0; i < 6; i++) ntsQuery(spec: spec),
      ];
      // Admission and mock entry are synchronous up to the gate await,
      // so the first four calls are already in-flight and the other
      // two are queued holding no slot.
      expect(api.asyncInFlight, 4);
      expect(api.queryDispatches, 4);
      api.asyncGate = null;
      gate.complete();
      await Future.wait(futures);
      expect(api.asyncMaxInFlight, 4);
      expect(api.queryDispatches, 6);
    });

    test('a queued call dispatches after a slot frees', () async {
      final gate = Completer<void>();
      api.asyncGate = () => gate.future;
      final first = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      final second = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      expect(api.queryDispatches, 1);
      api.asyncGate = null;
      gate.complete();
      await Future.wait([first, second]);
      expect(api.queryDispatches, 2);
      expect(api.asyncMaxInFlight, 1);
    });

    test('budget elapsing while queued fails with bridgeSaturation and '
        'never dispatches', () async {
      final gate = Completer<void>();
      api.asyncGate = () => gate.future;
      final holder = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      await expectLater(
        ntsQuery(spec: spec, bridgeConcurrencyCap: 1, timeoutMs: 40),
        throwsA(
          isA<NtsErrorTimeout>()
              .having((e) => e.phase, 'phase', TimeoutPhase.bridgeSaturation)
              .having((e) => e.trustBackend, 'trustBackend', isNull),
        ),
      );
      expect(api.queryDispatches, 1);
      api.asyncGate = null;
      gate.complete();
      await holder;
      // The timed-out waiter left no queue residue: a follow-up call
      // is admitted immediately.
      await ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      expect(api.queryDispatches, 2);
    });

    test('queue wait is charged against the forwarded timeoutMs', () async {
      final gate = Completer<void>();
      api.asyncGate = () => gate.future;
      final holder = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      final queued = ntsQuery(
        spec: spec,
        bridgeConcurrencyCap: 1,
        timeoutMs: 5000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      api.asyncGate = null;
      gate.complete();
      await Future.wait([holder, queued]);
      // `queued` dispatched last, so `lastQueryTimeoutMs` carries its
      // forwarded budget: the original 5000 minus ~60ms of queue wait.
      // The bounds are deliberately loose to stay timer-slop-proof.
      expect(api.lastQueryTimeoutMs, lessThan(5000));
      expect(api.lastQueryTimeoutMs, greaterThanOrEqualTo(4000));
    });

    test('gate is shared across top-level and client entry points', () async {
      final gate = Completer<void>();
      api.asyncGate = () => gate.future;
      final client = NtsClient();
      final holder = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      final queued = client.query(spec: spec, bridgeConcurrencyCap: 1);
      // The client call queued behind the top-level call: its FFI
      // dispatch has not happened.
      expect(api.lastClientQueryTimeoutMs, isNull);
      api.asyncGate = null;
      gate.complete();
      await Future.wait([holder, queued]);
      expect(api.lastClientQueryTimeoutMs, isNotNull);
      expect(api.asyncMaxInFlight, 1);
    });

    test('a larger-cap arrival overtakes only waiters its own cap '
        'strands', () async {
      final gates = [Completer<void>(), Completer<void>()];
      var next = 0;
      api.asyncGate = () => gates[next++].future;
      final holder = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      final stranded = ntsQuery(spec: spec, bridgeConcurrencyCap: 1);
      final wide = ntsQuery(spec: spec, bridgeConcurrencyCap: 3);
      // `wide`'s cap (3) clears the in-flight count (1), so it is
      // admitted immediately; `stranded`'s cap (1) keeps it queued
      // regardless, so no unfair overtake occurred.
      expect(api.queryDispatches, 2);
      gates[1].complete();
      await wide;
      // `wide` finishing brings in-flight back to 1, which still
      // does not clear `stranded`'s cap.
      expect(api.queryDispatches, 2);
      api.asyncGate = null;
      gates[0].complete();
      await Future.wait([holder, stranded]);
      expect(api.queryDispatches, 3);
    });
  });
}
