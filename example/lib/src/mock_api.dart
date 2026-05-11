// The example needs to construct a `RustLibApi` instance to feed
// `RustLib.initMock`, but `RustLibApi` is intentionally not part of the
// public barrel — it's an internal contract that exists only so unit
// tests and showcase apps can stub the bridge without loading a dylib.
// The same pattern is used in `test/ffi_smoke_test.dart`.
//
// Because `RustLibApi`'s overrides accept and return the FFI DTOs from
// `lib/src/ffi/api/nts.dart` (with their `PlatformInt64` microsecond
// fields and freezed-generated `NtsError`), this file imports those
// types directly rather than the public `package:nts/nts.dart` shapes
// that 3.0+ consumer code uses. The wrapper layer in
// `lib/src/api/nts.dart` converts at the boundary, so the rest of the
// example only ever sees the public types.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:nts/src/ffi/api/nts.dart'
    show
        NtsClient,
        NtsError,
        NtsServerSpec,
        NtsTimeSample,
        NtsTrustStatus,
        NtsWarmCookiesOutcome,
        PhaseTimings,
        TrustBackend,
        TrustMode;
import 'package:nts/src/ffi/frb_generated.dart' show RustLib, RustLibApi;

/// In-memory `RustLibApi` implementation used by the example app and the
/// widget smoke test as an explicit alternative to the bundled Rust dylib.
///
/// Returns plausible-looking NTS samples so the UI is exercisable on any
/// host without TLS/UDP plumbing. The example launches against the real
/// bridge by default; pass `--dart-define=NTS_BRIDGE=mock` to bind this
/// fake implementation instead (handy for offline UI work or for hosts
/// where the Rust toolchain isn't set up).
///
/// The 3.0.0 trust-anchor diagnostics surface (`NtsClient` per-instance
/// methods, `ntsTrustStatus()`, [TrustMode] / [TrustBackend]) is
/// stubbed alongside the top-level `ntsQuery` / `ntsWarmCookies` so
/// the example's TrustMode toggle, TrustStatus panel, and
/// per-handshake backend log lines work identically under the mock
/// and the real bridge.
class MockNtsApi implements RustLibApi {
  MockNtsApi({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// Per-fake-client trust mode pinned at construction so the
  /// `client.trustMode()` getter round-trips. Uses an [Expando]
  /// rather than a `Map<NtsClient, TrustMode>` so dropped fake
  /// clients are eligible for GC: every `TrustMode` toggle in the
  /// example mints a new fake client, and a strong-keyed map would
  /// pin every fake (and every per-client state attached to it)
  /// alive for the lifetime of the process. The `_RecordingApi` in
  /// `test/api_smoke_test.dart` uses a `Map` because tests are
  /// short-lived and benefit from a deterministic iterable view of
  /// the minted clients; the example app is the long-lived path
  /// and warrants the weak-key form.
  final Expando<TrustMode> _clientTrustModes = Expando<TrustMode>(
    'MockNtsApi._clientTrustModes',
  );

  /// Most-recent backend resolved by the *singleton* path
  /// (top-level `crateApiNtsNtsQuery` / `crateApiNtsNtsWarmCookies`)
  /// only. Surfaced through [crateApiNtsNtsTrustStatus] as
  /// `defaultClientBackend`, mirroring the real Rust-side semantics
  /// where caller-minted [NtsClient] instances do not affect the
  /// singleton snapshot. Per-client paths track their backend
  /// out-of-band on the returned `NtsTimeSample` /
  /// `NtsWarmCookiesOutcome`.
  TrustBackend? _lastResolvedBackend;

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

    // Singleton path -- record the backend on the snapshot so
    // `crateApiNtsNtsTrustStatus().defaultClientBackend` matches
    // real Rust-side semantics (singleton-only attribution).
    _lastResolvedBackend = TrustBackend.platform;
    return _mockSample(rttMs: rttMs, backend: TrustBackend.platform);
  }

  @override
  Future<NtsWarmCookiesOutcome> crateApiNtsNtsWarmCookies({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _lastResolvedBackend = TrustBackend.platform;
    return _mockWarm(backend: TrustBackend.platform);
  }

  @override
  Future<PhaseTimings> crateApiNtsPhaseTimingsDefault() async =>
      _mockPhaseTimings();

  // --- NtsClient surface --------------------------------------------
  //
  // Mirrors the `_RecordingApi` / `_FakeFfiNtsClient` pair in
  // `test/api_smoke_test.dart`: minted clients are
  // `_FakeMockNtsClient` instances whose method bodies forward back
  // through `RustLib.instance.api`, which dispatches to the stubs
  // below.

  @override
  NtsClient crateApiNtsNtsClientNew() {
    final fake = _FakeMockNtsClient();
    _clientTrustModes[fake] = TrustMode.platformWithFallback;
    return fake;
  }

  @override
  NtsClient crateApiNtsNtsClientWithTrustMode({required TrustMode trustMode}) {
    final fake = _FakeMockNtsClient();
    _clientTrustModes[fake] = trustMode;
    return fake;
  }

  @override
  TrustMode crateApiNtsNtsClientTrustMode({required NtsClient that}) =>
      _clientTrustModes[that] ?? TrustMode.platformWithFallback;

  @override
  Future<NtsTimeSample> crateApiNtsNtsClientQuery({
    required NtsClient that,
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    final rttMs = 25 + _random.nextInt(40);
    await Future<void>.delayed(Duration(milliseconds: rttMs));
    final backend = _resolveBackendForClient(that);
    return _mockSample(rttMs: rttMs, backend: backend);
  }

  @override
  Future<NtsWarmCookiesOutcome> crateApiNtsNtsClientWarmCookies({
    required NtsClient that,
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final backend = _resolveBackendForClient(that);
    return _mockWarm(backend: backend);
  }

  @override
  bool crateApiNtsNtsClientInvalidate({
    required NtsClient that,
    required NtsServerSpec spec,
  }) => false;

  @override
  void crateApiNtsNtsClientClear({required NtsClient that}) {}

  @override
  NtsTrustStatus crateApiNtsNtsTrustStatus() => NtsTrustStatus(
    defaultClientBackend: _lastResolvedBackend,
    androidPlatformInitSucceeded: false,
    androidHybridFallbackCount: BigInt.zero,
  );

  /// Resolve the simulated backend for a per-client handshake. A
  /// [TrustMode.platformOnly] client occasionally surfaces
  /// `NtsErrorTrustBackendUnavailable` so the example exercises the
  /// strict-mode error path; a [TrustMode.platformWithFallback]
  /// client occasionally reports
  /// [TrustBackend.platformWithHybridFallback] so the on-screen log
  /// shows backend variety. Both cases are dialled in at sub-15%
  /// rates so the dominant signal stays the happy-path
  /// [TrustBackend.platform] case.
  TrustBackend _resolveBackendForClient(NtsClient that) {
    final mode = _clientTrustModes[that] ?? TrustMode.platformWithFallback;
    if (mode == TrustMode.platformOnly && _random.nextInt(10) == 0) {
      throw const NtsError.trustBackendUnavailable(
        'mock: PlatformOnly refused fallback to webpki-roots bundle',
      );
    }
    return mode == TrustMode.platformWithFallback && _random.nextInt(8) == 0
        ? TrustBackend.platformWithHybridFallback
        : TrustBackend.platform;
  }

  // Pure DTO factories: these are shared by both the singleton and
  // per-client paths and intentionally do NOT touch
  // `_lastResolvedBackend`. Singleton callers must record the
  // backend at their own call site (see crateApiNtsNtsQuery /
  // crateApiNtsNtsWarmCookies) so per-client paths cannot leak into
  // the singleton snapshot.
  NtsTimeSample _mockSample({
    required int rttMs,
    required TrustBackend backend,
  }) {
    final nowMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return NtsTimeSample(
      utcUnixMicros: PlatformInt64Util.from(nowMicros),
      roundTripMicros: PlatformInt64Util.from(rttMs * 1000),
      serverStratum: 1,
      aeadId: 15,
      freshCookies: 1,
      phaseTimings: _mockPhaseTimings(),
      trustBackend: backend,
    );
  }

  NtsWarmCookiesOutcome _mockWarm({required TrustBackend backend}) =>
      NtsWarmCookiesOutcome(
        freshCookies: 8,
        phaseTimings: _mockPhaseTimings(),
        trustBackend: backend,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'MockNtsApi: ${invocation.memberName} not stubbed',
  );
}

/// In-memory stand-in for the FFI-side `NtsClient` opaque handle.
/// Each method forwards back through `RustLib.instance.api` so the
/// active [MockNtsApi] observes the call exactly as the real
/// `NtsClientImpl` would have routed it. `dispose` / `isDisposed`
/// are stubbed because the mock has no `Arc` to release.
class _FakeMockNtsClient implements NtsClient {
  @override
  void clear() => RustLib.instance.api.crateApiNtsNtsClientClear(that: this);

  @override
  bool invalidate({required NtsServerSpec spec}) => RustLib.instance.api
      .crateApiNtsNtsClientInvalidate(that: this, spec: spec);

  @override
  TrustMode trustMode() =>
      RustLib.instance.api.crateApiNtsNtsClientTrustMode(that: this);

  @override
  Future<NtsTimeSample> query({
    required NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
  }) => RustLib.instance.api.crateApiNtsNtsClientQuery(
    that: this,
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
  );

  @override
  Future<NtsWarmCookiesOutcome> warmCookies({
    required NtsServerSpec spec,
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

PhaseTimings _mockPhaseTimings() => PhaseTimings(
  dnsMicros: PlatformInt64Util.from(0),
  connectMicros: PlatformInt64Util.from(0),
  tlsHandshakeMicros: PlatformInt64Util.from(0),
  keRecordIoMicros: PlatformInt64Util.from(0),
);
