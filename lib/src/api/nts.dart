// Hand-written stable surface for `package:nts`.
//
// This file is the public contract consumers see when they
// `import 'package:nts/nts.dart'`. It exposes wrapper functions that
// accept and return only the hand-written DTOs in `models.dart` and
// the hand-written error sealed class in `errors.dart`, and converts
// across the FRB-generated boundary in `lib/src/ffi/api/nts.dart`
// internally.
//
// The wrapper exists for two reasons:
//
// 1. Function signatures: FRB v2 codegen marks every Rust argument as
//    a `required` named parameter on the Dart side, with no support
//    for optional / defaulted parameters. The wrapper restores idiomatic
//    Dart signatures with named optional parameters and defaults
//    (`kDefaultTimeoutMs`, `kDefaultDnsConcurrencyCap`).
// 2. Type shape: the FFI DTOs use FRB-specific types like
//    `PlatformInt64` and a freezed-generated `NtsError`. Converting to
//    plain Dart `int` and a hand-written sealed `NtsError` at this
//    boundary means a Rust-side struct rename or reorder no longer
//    becomes a Dart source break for downstream callers.
//
// See `ARCHITECTURE.md`'s "Public API stability layer" section for
// the full rationale.

import 'dart:typed_data';
import '../ffi/api/nts.dart' as ffi;
import 'errors.dart';
import 'models.dart';

export 'errors.dart';
export 'models.dart';

/// Default per-call wall-clock budget for [ntsQuery] / [ntsWarmCookies]
/// / [NtsClient.query] / [NtsClient.warmCookies], in milliseconds.
///
/// Sized to cover one DNS lookup plus the NTS-KE TLS 1.3 handshake plus
/// the NTPv4 UDP round-trip against a public server over a typical
/// consumer network, while still failing fast against an unreachable
/// host. Centralising the constant gives callers a stable name to refer
/// to "the package's tuned default" rather than hardcoding the number.
/// Override per-call by passing an explicit `timeoutMs` argument; values
/// must lie in `1..4294967295` (the FFI encoding range, validated at
/// the wrapper boundary).
const int kDefaultTimeoutMs = 5000;

/// Default per-call ceiling on in-flight DNS resolver workers, applied
/// process-wide by [ntsQuery] / [ntsWarmCookies] / [NtsClient.query] /
/// [NtsClient.warmCookies].
///
/// Sized for mobile devices: each in-flight `getaddrinfo` worker holds
/// an OS thread plus a 512 KB-1 MB pthread stack, and `getaddrinfo`
/// itself is non-cancellable, so a stalled lookup is detached and
/// finishes in the background. The cap bounds how many such workers
/// can accumulate before subsequent calls short-circuit with
/// [NtsError.timeout] ([TimeoutPhase.dnsSaturation]) rather than
/// spawning another. Raise per-call on hosts with more headroom by
/// passing an explicit `dnsConcurrencyCap` argument; values must lie
/// in `1..4294967295` (the FFI encoding range, validated at the
/// wrapper boundary).
const int kDefaultDnsConcurrencyCap = 4;

/// Run a complete authenticated NTPv4 exchange against `spec`.
///
/// On the first call (or after the cookie pool is exhausted) this
/// performs a full NTS-KE handshake before sending the NTPv4 request;
/// subsequent calls reuse the cached AEAD keys and spend a stored
/// cookie.
///
/// `timeoutMs` is a single global wall-clock budget that spans DNS,
/// NTS-KE (TCP connect, TLS handshake, record I/O) and the AEAD-NTPv4
/// UDP exchange as one shrinking deadline. Defaults to
/// [kDefaultTimeoutMs] when omitted.
///
/// `dnsConcurrencyCap` is a per-call ceiling on the process-wide bounded
/// DNS resolver: if the global in-flight counter has already reached
/// this value when the call attempts a lookup, the call short-circuits
/// with `NtsError.timeout` instead of spawning another worker thread.
/// Defaults to [kDefaultDnsConcurrencyCap] when omitted, which inherits
/// the package's built-in default. Because admission is gated against a
/// single process-wide counter, every admitted worker counts toward
/// every caller's threshold — see `ARCHITECTURE.md`'s "Timeout budget
/// and bounded DNS" section for the full mechanic and the asymmetric
/// starvation behaviour between mixed-cap callers.
///
/// The returned [NtsTimeSample] exposes the raw protocol primitives,
/// not a finished synchronized clock. `utcUnixMicros` is the server
/// transmit timestamp exactly as it appeared on the wire; it does not
/// include any compensation for the one-way network delay between the
/// server and this caller. To approximate the server's clock at the
/// moment the reply arrived, callers should add `roundTripMicros / 2`
/// to `utcUnixMicros` (the standard NTP assumption of a symmetric
/// path). For high-precision synchronization, take a burst of samples
/// and pick the one with the smallest `roundTripMicros` before applying
/// that adjustment.
///
/// All integer arguments (`spec.port`, `timeoutMs`, `dnsConcurrencyCap`)
/// are validated against the FFI encoding range (`1..65535` for the
/// port, `1..4294967295` for the two `u32` parameters) before any FFI
/// dispatch; out-of-range values cause the returned `Future` to
/// complete with [NtsError.invalidSpec] without reaching the Rust
/// boundary, on the same `await`/`catch` shape as every other failure
/// mode this wrapper surfaces.
///
/// Throws an [NtsError] on every failure path.
Future<NtsTimeSample> ntsQuery({
  required NtsServerSpec spec,
  int timeoutMs = kDefaultTimeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
}) async {
  _validateRanges(
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
  );
  try {
    final ffiSample = await ffi.ntsQuery(
      spec: _ffiSpec(spec),
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    );
    return _publicSample(ffiSample);
  } on ffi.NtsError catch (err, stack) {
    // Preserve the original FFI-side stack trace through the
    // conversion so debuggers point at the FRB dispatcher / Rust
    // boundary where the error originated, not at this catch site.
    Error.throwWithStackTrace(_publicError(err), stack);
  }
}

/// Force a fresh NTS-KE handshake against `spec` and return the cookie
/// count along with the per-phase wall-clock breakdown of the handshake.
/// Replaces any cached session for that spec.
///
/// `timeoutMs` and `dnsConcurrencyCap` carry the same semantics as on
/// [ntsQuery] and default to [kDefaultTimeoutMs] /
/// [kDefaultDnsConcurrencyCap] when omitted.
///
/// The returned [NtsWarmCookiesOutcome.phaseTimings] only covers the
/// KE pipeline (DNS, connect, TLS, KE record I/O); there is no UDP
/// NTP exchange on this path. There is no [TimeoutPhase.ntp]-tagged
/// field on [PhaseTimings] in the first place — [PhaseTimings] only
/// names the four pre-NTP phases — so "implicitly zero" here is
/// shorthand for "the UDP send/recv leg never ran on this code path."
///
/// All integer arguments are validated against the FFI encoding range
/// before dispatch on the same terms as [ntsQuery]; out-of-range values
/// cause the returned `Future` to complete with [NtsError.invalidSpec]
/// without reaching the Rust boundary.
///
/// Throws an [NtsError] on every failure path.
Future<NtsWarmCookiesOutcome> ntsWarmCookies({
  required NtsServerSpec spec,
  int timeoutMs = kDefaultTimeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
}) async {
  _validateRanges(
    spec: spec,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
  );
  try {
    final ffiOutcome = await ffi.ntsWarmCookies(
      spec: _ffiSpec(spec),
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    );
    return _publicWarm(ffiOutcome);
  } on ffi.NtsError catch (err, stack) {
    // Preserve the original FFI-side stack trace; see the comment in
    // `ntsQuery` above.
    Error.throwWithStackTrace(_publicError(err), stack);
  }
}

/// Snapshot the bounded DNS resolver pool counters. Synchronous (no
/// future / isolate hop): backed by four atomic-relaxed loads, cheap
/// enough to call from a UI poll loop.
///
/// Requires `await NtsRustLib.init()` to have completed on the calling
/// isolate before invocation: the four atomic reads happen on the Rust
/// side and dispatch through the FRB v2 dispatch table even though the
/// call returns synchronously, so a missed initialization fails with a
/// low-level FRB error rather than a structured [NtsError]. See the
/// "Initialization has two layers" section of `README.md` for the full
/// bootstrap contract (including the separate Android `NtsPlugin` JNI
/// bootstrap that runs before `main()`).
///
/// Counters are process-wide and include workers spawned by every
/// concurrent caller, including those passing different
/// `dnsConcurrencyCap` values — the underlying pool is shared by
/// design (see `ARCHITECTURE.md`'s "Timeout budget and bounded DNS"
/// section). The snapshot is racy by construction: each counter is
/// read with an independent relaxed atomic load, so combinations
/// across counters can be slightly stale — e.g. `inFlight` lagging
/// `recovered` by one bump, or `inFlight > highWaterMark` for the
/// few-nanosecond window between a worker's admission increment and
/// the subsequent `fetch_max` on the high-water mark. The guarantee
/// is per-counter monotonicity across consecutive snapshots
/// (cumulative counters and `highWaterMark` never decrease; every
/// loaded value is one the counter actually held at some real
/// moment), not a cross-counter invariant within a single snapshot.
///
/// Cumulative counters (`recovered`, `refused`) and the
/// `highWaterMark` are *not* reset by this call. For windowed
/// measurements, snapshot at `t0` and `t1` and subtract.
///
/// Operators can use the four counters to distinguish three failure
/// modes that all collapse onto `NtsError.timeout` in the hot-path
/// error contract:
///
/// - **Healthy resolver, occasional bursts** — `inFlight` oscillates
///   below the cap, `highWaterMark` plateaus a few steps above
///   steady state, `recovered` climbs in lockstep with traffic,
///   `refused` stays flat.
/// - **Cap-bound deployment** — `refused` is climbing; raising the
///   `dnsConcurrencyCap` argument on [ntsQuery] / [ntsWarmCookies]
///   would lower the timeout error rate.
/// - **libc-level resolver wedge** — `inFlight == cap`, `recovered`
///   flat, `refused` climbing. The system resolver is not making
///   progress; raising the cap would only push more threads into the
///   same wedge. This is the saturation signature operators should
///   alert on.
NtsDnsPoolStats ntsDnsPoolStats() => _publicStats(ffi.ntsDnsPoolStats());

/// Snapshot the process-global trust-anchor diagnostic state.
/// Synchronous (no future / isolate hop): backed by three atomic
/// loads, cheap enough to call from a UI poll loop or a pre-flight
/// "can I even validate against the platform store?" check.
///
/// Requires `await NtsRustLib.init()` to have completed on the calling
/// isolate before invocation: the three atomic reads happen on the
/// Rust side and dispatch through the FRB v2 dispatch table even
/// though the call returns synchronously, so a missed initialization
/// fails with a low-level FRB error rather than a structured
/// [NtsError]. See the "Initialization has two layers" section of
/// `README.md` for the full bootstrap contract; the
/// `androidPlatformInitSucceeded` and `androidHybridFallbackCount`
/// observables below are populated by the separate Android
/// `NtsPlugin` JNI bootstrap that runs before `main()`, distinct from
/// `NtsRustLib.init()`.
///
/// Returns six observables that callers cannot recover from a
/// per-query [NtsTimeSample] alone:
///
/// 1. `defaultClientBackend` — backend the *default singleton*
///    [NtsClient] (used by [ntsQuery] and [ntsWarmCookies]) most
///    recently resolved to. `null` when no handshake has run yet
///    against the singleton. This is an overwrite-on-store event
///    marker, not a steady-state signal: a transient
///    `webpkiRoots`-resolving handshake latches this field
///    permanently until the next `platform`-resolving one. Use the
///    three counters in (2)–(4) for dashboard panels that need
///    trend visibility. Custom-client callers should read
///    [NtsTimeSample.trustBackend] / [NtsWarmCookiesOutcome.trustBackend]
///    for accurate per-client attribution.
/// 2. `defaultBackendPlatformCount` — cumulative count of singleton
///    handshakes that resolved to [TrustBackend.platform].
/// 3. `defaultBackendHybridCount` — cumulative count of singleton
///    handshakes that resolved to
///    [TrustBackend.platformWithHybridFallback]. Always zero on
///    non-Android platforms.
/// 4. `defaultBackendWebpkiCount` — cumulative count of singleton
///    handshakes that resolved to [TrustBackend.webpkiRoots].
/// 5. `androidPlatformInitSucceeded` — `true` iff the Android JNI
///    bootstrap reported success at least once. `false` on every
///    other platform.
/// 6. `androidHybridFallbackCount` — cumulative count of TLS chains
///    the Android hybrid verifier has accepted via the
///    `webpki-roots` fallback path. Always zero on non-Android
///    platforms.
///
/// Per-counter monotonicity holds across consecutive snapshots; the
/// snapshot is intended for human / dashboard consumption, not for
/// cross-thread synchronisation. Cross-counter invariants within a
/// single snapshot do not hold — the sum of the three
/// `defaultBackend*Count` fields can be observed to lag the
/// [NtsTrustStatus.defaultClientBackend] pointer by a single
/// store-pair across concurrent snapshots.
NtsTrustStatus ntsTrustStatus() => _publicTrustStatus(ffi.ntsTrustStatus());

/// Owned NTS client handle.
///
/// Each [NtsClient] owns its own per-host session table on the Rust
/// side, so two instances never share cookie or key state. The
/// top-level convenience functions [ntsQuery] and [ntsWarmCookies]
/// continue to delegate to a process-wide default client whose state
/// is shared across all callers (the same behaviour as 1.x / 2.x);
/// construct an explicit [NtsClient] when you need:
///
/// - **Test isolation**, so one test's cached sessions do not bleed
///   into another's.
/// - **On-demand cache invalidation** via [invalidate] (per-host) or
///   [clear] (everything), e.g. for diagnostics tools that want to
///   force a fresh NTS-KE handshake.
/// - **Scope-bounded session ownership**, so the cache lives only as
///   long as the owning client and is bounded to the hosts that
///   client is interested in.
///
/// The client is safe to share across same-isolate async callers;
/// the underlying Rust table is mutex-guarded, so concurrent
/// `await`-ed calls on a single client serialize only for the brief
/// window each cache lookup needs.
///
/// The handle wraps a `flutter_rust_bridge` `RustOpaque` that owns
/// a finalizable native `Arc`, which is **not** sendable across
/// isolate boundaries through a `SendPort` — a different isolate
/// must construct its own [NtsClient] (which gets its own
/// independent session table) rather than receiving one minted on
/// the main isolate. The session table is owned by the `NtsClient`
/// handle, not by the isolate; the top-level [ntsQuery] /
/// [ntsWarmCookies] functions delegate to a process-wide default
/// client whose table is shared across every isolate that calls
/// them. There is no clone-as-sendable-token API on the public
/// surface today.
///
/// **Initialization**: `await NtsRustLib.init()` from
/// `package:nts/src/ffi/frb_generated.dart` must have completed
/// before the [NtsClient] default constructor or any of its
/// methods is called — the constructor synchronously dispatches
/// through the FRB bridge to mint the underlying Rust handle, and
/// the methods reach the same dispatch table. This is the same
/// initialization step the top-level [ntsQuery] / [ntsWarmCookies]
/// functions require; see the library-level dartdoc on
/// `package:nts/nts.dart` for the full bootstrap walk-through.
class NtsClient {
  final ffi.NtsClient _inner;

  NtsClient._(this._inner);

  /// Construct a fresh client whose session table starts empty. Two
  /// clients constructed this way never share session state with each
  /// other or with the process-wide default used by the top-level
  /// [ntsQuery] / [ntsWarmCookies] functions.
  ///
  /// `trustMode` selects the trust-anchor policy applied to every
  /// handshake this client initiates; defaults to
  /// [TrustMode.platformWithFallback], which preserves the silent
  /// `webpki-roots` downgrade behaviour matching the top-level
  /// convenience functions and every release prior to 3.0.0. Pass
  /// [TrustMode.platformOnly] to refuse the downgrade and surface
  /// `NtsErrorTrustBackendUnavailable` when the platform verifier
  /// cannot be constructed; appropriate when a pinned corporate CA
  /// or MDM-installed root is the load-bearing trust anchor and a
  /// silent fallback to the static bundle would defeat the
  /// deployment's TLS-inspection posture. Pass [TrustMode.bundledOnly]
  /// to bypass the platform trust store entirely and only trust
  /// the bundled root certificates (`webpki-roots`). Pass [TrustMode.custom]
  /// alongside a non-empty list of certificates in [customRoots] to trust
  /// only those caller-supplied custom root certificates. The choice is
  /// immutable for the life of the client.
  ///
  /// Synchronous: dispatches through the FRB bridge to mint the
  /// underlying Rust handle in-line. `await NtsRustLib.init()` must
  /// have completed first; calling this before init throws a
  /// `StateError` from FRB's dispatcher rather than an [NtsError].
  /// Apps that mint a long-lived [NtsClient] during startup should
  /// do so after the same `await NtsRustLib.init()` they would do
  /// before calling [ntsQuery].
  factory NtsClient({
    TrustMode trustMode = TrustMode.platformWithFallback,
    List<int>? customRoots,
  }) {
    if (customRoots != null && trustMode != TrustMode.custom) {
      throw ArgumentError(
        'customRoots can only be set when trustMode is TrustMode.custom',
      );
    }
    if (trustMode == TrustMode.custom &&
        (customRoots == null || customRoots.isEmpty)) {
      throw ArgumentError(
        'customRoots must be provided and non-empty when trustMode is TrustMode.custom',
      );
    }
    final inner = trustMode == TrustMode.platformWithFallback
        ? ffi.NtsClient()
        : ffi.NtsClient.withTrustMode(
            trustMode: _ffiTrustMode(trustMode, customRoots),
          );
    return NtsClient._(inner);
  }

  /// Trust-anchor policy this client was constructed with.
  /// Synchronous: backed by a one-byte read on the Rust side.
  ///
  /// Requires `await NtsRustLib.init()` to have completed on the
  /// calling isolate before invocation: the read happens on the Rust
  /// side and dispatches through the FRB v2 dispatch table even
  /// though the call returns synchronously, so a missed
  /// initialization fails with a low-level FRB error rather than a
  /// structured [NtsError]. See the "Initialization has two layers"
  /// section of `README.md` for the full bootstrap contract.
  TrustMode get trustMode => _publicTrustMode(_inner.trustMode());

  /// Per-client equivalent of the top-level [ntsQuery]. The cookie
  /// pool, AEAD keys, and KE session live in this client's table; on
  /// the first call (or after the cookie pool is exhausted) a full
  /// NTS-KE handshake runs, then subsequent calls reuse the cached
  /// session.
  ///
  /// Parameter semantics for `timeoutMs` and `dnsConcurrencyCap` are
  /// identical to [ntsQuery]; defaults come from [kDefaultTimeoutMs]
  /// and [kDefaultDnsConcurrencyCap], and out-of-range values cause
  /// the returned `Future` to complete with [NtsError.invalidSpec] on
  /// the same terms as the top-level wrapper. The [NtsTimeSample]
  /// return shape is identical too — see [ntsQuery]'s dartdoc for the
  /// raw protocol primitives the sample exposes and how to apply the
  /// one-way-delay correction.
  ///
  /// Throws an [NtsError] on every failure path.
  Future<NtsTimeSample> query({
    required NtsServerSpec spec,
    int timeoutMs = kDefaultTimeoutMs,
    int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
  }) async {
    _validateRanges(
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    );
    try {
      final ffiSample = await _inner.query(
        spec: _ffiSpec(spec),
        timeoutMs: timeoutMs,
        dnsConcurrencyCap: dnsConcurrencyCap,
      );
      return _publicSample(ffiSample);
    } on ffi.NtsError catch (err, stack) {
      // Preserve the original FFI-side stack trace through the
      // conversion; see the comment in the top-level `ntsQuery`.
      Error.throwWithStackTrace(_publicError(err), stack);
    }
  }

  /// Per-client equivalent of the top-level [ntsWarmCookies]. Forces
  /// a fresh NTS-KE handshake and ingests the delivered cookie pool
  /// into this client's table, replacing any previously cached
  /// session for the spec.
  ///
  /// All integer arguments are validated against the FFI encoding
  /// range before dispatch on the same terms as [ntsQuery] /
  /// [ntsWarmCookies]; out-of-range values cause the returned `Future`
  /// to complete with [NtsError.invalidSpec] without reaching the
  /// Rust boundary.
  ///
  /// Throws an [NtsError] on every failure path.
  Future<NtsWarmCookiesOutcome> warmCookies({
    required NtsServerSpec spec,
    int timeoutMs = kDefaultTimeoutMs,
    int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
  }) async {
    _validateRanges(
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    );
    try {
      final ffiOutcome = await _inner.warmCookies(
        spec: _ffiSpec(spec),
        timeoutMs: timeoutMs,
        dnsConcurrencyCap: dnsConcurrencyCap,
      );
      return _publicWarm(ffiOutcome);
    } on ffi.NtsError catch (err, stack) {
      Error.throwWithStackTrace(_publicError(err), stack);
    }
  }

  /// Drop this client's cached session for `spec`'s `host:port`, if
  /// any. Returns `true` when an entry was removed, `false` when no
  /// session was cached for that key. The next [query] or
  /// [warmCookies] for that spec triggers a fresh NTS-KE handshake.
  ///
  /// Synchronous: backed by one mutex acquisition and one
  /// `HashMap::remove` on the Rust side; no isolate hop. The
  /// wrapper validates `spec.port` against the FRB-encodable range
  /// `1..65535` first; out-of-range ports throw
  /// [NtsError.invalidSpec] with a wrapper-authored message before
  /// any FFI dispatch (matching the surface the four async wrappers
  /// expose via [ntsQuery] / [ntsWarmCookies]). Empty host and any
  /// other semantically-invalid-but-encodable spec trivially have
  /// no cached entry and return `false`.
  ///
  /// Requires `await NtsRustLib.init()` to have completed on the
  /// calling isolate before invocation: the mutex acquisition and
  /// `HashMap::remove` happen on the Rust side and dispatch through
  /// the FRB v2 dispatch table even though the call returns
  /// synchronously, so a missed initialization fails with a
  /// low-level FRB error rather than a structured [NtsError]. See
  /// the "Initialization has two layers" section of `README.md` for
  /// the full bootstrap contract.
  bool invalidate(NtsServerSpec spec) {
    _validatePort(spec);
    return _inner.invalidate(spec: _ffiSpec(spec));
  }

  /// Drop every cached session in this client's table. Cheap;
  /// intended for test cleanup and for apps that want to bound
  /// long-lived process memory by resetting the cache between work
  /// batches.
  ///
  /// Synchronous: backed by one mutex acquisition and one
  /// `HashMap::clear` on the Rust side; no isolate hop.
  ///
  /// Requires `await NtsRustLib.init()` to have completed on the
  /// calling isolate before invocation: the mutex acquisition and
  /// `HashMap::clear` happen on the Rust side and dispatch through
  /// the FRB v2 dispatch table even though the call returns
  /// synchronously, so a missed initialization fails with a
  /// low-level FRB error rather than a structured [NtsError]. See
  /// the "Initialization has two layers" section of `README.md` for
  /// the full bootstrap contract.
  void clear() => _inner.clear();
}

// --- input validation -----------------------------------------------
//
// Run before every wrapper dispatches into the FFI layer. The three
// integer arguments hit FRB-generated `sse_encode_u_16` /
// `sse_encode_u_32` codecs that `RangeError` on out-of-range values
// before the Rust code ever runs, which would escape the wrapper's
// `on ffi.NtsError catch` contract and surface to consumers as a
// non-`NtsError` exception. Validating up front and translating to
// `NtsError.invalidSpec` keeps the wrapper's "single error surface"
// promise honest.
//
// `port` is restricted to the semantically meaningful range `1..65535`
// rather than the encoder's `0..65535`: Rust's spec validator already
// rejects `port == 0` with its own `InvalidSpec("port must be
// non-zero")`, and front-loading the check produces a wrapper-authored
// `NtsError.invalidSpec` on the returned `Future` (the four wrapper
// entry points are `async`, so the error materialises on `await`)
// before any FFI dispatch instead of a Rust-authored one after a
// futile FFI hop. `timeoutMs` and `dnsConcurrencyCap` are restricted
// to `1..0xFFFFFFFF`: zero used to be a sentinel for "inherit the
// Rust-side default" in 1.x and 3.0.x, but consumers are now steered
// toward the named `kDefault*` constants which expose the actual
// numeric values.

const int _kU32Max = 0xFFFFFFFF;

void _validatePort(NtsServerSpec spec) {
  if (spec.port < 1 || spec.port > 65535) {
    throw NtsError.invalidSpec(
      message: 'port ${spec.port} is outside the valid range 1..65535',
    );
  }
}

void _validateRanges({
  required NtsServerSpec spec,
  required int timeoutMs,
  required int dnsConcurrencyCap,
}) {
  _validatePort(spec);
  if (timeoutMs < 1 || timeoutMs > _kU32Max) {
    throw NtsError.invalidSpec(
      message:
          'timeoutMs $timeoutMs is outside the valid range 1..$_kU32Max; '
          'pass kDefaultTimeoutMs ($kDefaultTimeoutMs) to inherit the '
          'package default',
    );
  }
  if (dnsConcurrencyCap < 1 || dnsConcurrencyCap > _kU32Max) {
    throw NtsError.invalidSpec(
      message:
          'dnsConcurrencyCap $dnsConcurrencyCap is outside the valid '
          'range 1..$_kU32Max; pass kDefaultDnsConcurrencyCap '
          '($kDefaultDnsConcurrencyCap) to inherit the package default',
    );
  }
}

// --- conversion layer (FFI <-> public) -------------------------------
//
// All FFI types stay scoped to this file. Conversions are intentionally
// total (no fallback / catch-all arms) so a future Rust-side variant
// addition surfaces as an exhaustiveness error here rather than as a
// silently-dropped variant at the consumer.

ffi.NtsServerSpec _ffiSpec(NtsServerSpec spec) =>
    ffi.NtsServerSpec(host: spec.host, port: spec.port);

NtsTimeSample _publicSample(ffi.NtsTimeSample s) => NtsTimeSample(
  utcUnixMicros: s.utcUnixMicros.toInt(),
  roundTripMicros: s.roundTripMicros.toInt(),
  serverStratum: s.serverStratum,
  aeadId: s.aeadId,
  freshCookies: s.freshCookies,
  phaseTimings: _publicPhase(s.phaseTimings),
  trustBackend: _publicTrustBackend(s.trustBackend),
);

NtsWarmCookiesOutcome _publicWarm(ffi.NtsWarmCookiesOutcome o) =>
    NtsWarmCookiesOutcome(
      freshCookies: o.freshCookies,
      phaseTimings: _publicPhase(o.phaseTimings),
      trustBackend: _publicTrustBackend(o.trustBackend),
    );

PhaseTimings _publicPhase(ffi.PhaseTimings p) => PhaseTimings(
  dnsMicros: p.dnsMicros.toInt(),
  connectMicros: p.connectMicros.toInt(),
  tlsHandshakeMicros: p.tlsHandshakeMicros.toInt(),
  keRecordIoMicros: p.keRecordIoMicros.toInt(),
);

NtsDnsPoolStats _publicStats(ffi.NtsDnsPoolStats s) => NtsDnsPoolStats(
  inFlight: s.inFlight,
  highWaterMark: s.highWaterMark,
  recovered: s.recovered,
  refused: s.refused,
);

TimeoutPhase _publicTimeoutPhase(ffi.TimeoutPhase phase) => switch (phase) {
  ffi.TimeoutPhase.dnsSaturation => TimeoutPhase.dnsSaturation,
  ffi.TimeoutPhase.dnsTimeout => TimeoutPhase.dnsTimeout,
  ffi.TimeoutPhase.connect => TimeoutPhase.connect,
  ffi.TimeoutPhase.tls => TimeoutPhase.tls,
  ffi.TimeoutPhase.keRecordIo => TimeoutPhase.keRecordIo,
  ffi.TimeoutPhase.ntp => TimeoutPhase.ntp,
};

NtsError _publicError(ffi.NtsError err) => switch (err) {
  ffi.NtsError_InvalidSpec(:final field0) => NtsError.invalidSpec(
    message: field0,
  ),
  ffi.NtsError_Network(:final message, :final trustBackend) => NtsError.network(
    message: message,
    trustBackend: _maybePublicTrustBackend(trustBackend),
  ),
  ffi.NtsError_KeProtocol(:final message, :final trustBackend) =>
    NtsError.keProtocol(
      message: message,
      trustBackend: _maybePublicTrustBackend(trustBackend),
    ),
  ffi.NtsError_NtpProtocol(:final message, :final trustBackend) =>
    NtsError.ntpProtocol(
      message: message,
      trustBackend: _maybePublicTrustBackend(trustBackend),
    ),
  ffi.NtsError_Authentication(:final message, :final trustBackend) =>
    NtsError.authentication(
      message: message,
      trustBackend: _maybePublicTrustBackend(trustBackend),
    ),
  ffi.NtsError_Timeout(:final phase, :final trustBackend) => NtsError.timeout(
    phase: _publicTimeoutPhase(phase),
    trustBackend: _maybePublicTrustBackend(trustBackend),
  ),
  ffi.NtsError_NoCookies(:final trustBackend) => NtsError.noCookies(
    trustBackend: _maybePublicTrustBackend(trustBackend),
  ),
  ffi.NtsError_TrustBackendUnavailable(:final field0) =>
    NtsError.trustBackendUnavailable(message: field0),
  ffi.NtsError_Internal(:final field0) => NtsError.internal(message: field0),
};

TrustBackend? _maybePublicTrustBackend(ffi.TrustBackend? b) =>
    b == null ? null : _publicTrustBackend(b);

TrustBackend _publicTrustBackend(ffi.TrustBackend b) => switch (b) {
  ffi.TrustBackend.platform => TrustBackend.platform,
  ffi.TrustBackend.platformWithHybridFallback =>
    TrustBackend.platformWithHybridFallback,
  ffi.TrustBackend.webpkiRoots => TrustBackend.webpkiRoots,
  ffi.TrustBackend.custom => TrustBackend.custom,
};

TrustMode _publicTrustMode(ffi.TrustMode m) => switch (m) {
  ffi.TrustMode_PlatformWithFallback() => TrustMode.platformWithFallback,
  ffi.TrustMode_PlatformOnly() => TrustMode.platformOnly,
  ffi.TrustMode_BundledOnly() => TrustMode.bundledOnly,
  ffi.TrustMode_Custom() => TrustMode.custom,
};

ffi.TrustMode _ffiTrustMode(
  TrustMode m, [
  List<int>? customRoots,
]) => switch (m) {
  TrustMode.platformWithFallback => const ffi.TrustMode.platformWithFallback(),
  TrustMode.platformOnly => const ffi.TrustMode.platformOnly(),
  TrustMode.bundledOnly => const ffi.TrustMode.bundledOnly(),
  TrustMode.custom => ffi.TrustMode.custom(Uint8List.fromList(customRoots!)),
};

NtsTrustStatus _publicTrustStatus(ffi.NtsTrustStatus s) => NtsTrustStatus(
  defaultClientBackend: s.defaultClientBackend == null
      ? null
      : _publicTrustBackend(s.defaultClientBackend!),
  defaultBackendPlatformCount: s.defaultBackendPlatformCount,
  defaultBackendHybridCount: s.defaultBackendHybridCount,
  defaultBackendWebpkiCount: s.defaultBackendWebpkiCount,
  defaultBackendCustomCount: s.defaultBackendCustomCount,
  androidPlatformInitSucceeded: s.androidPlatformInitSucceeded,
  androidHybridFallbackCount: s.androidHybridFallbackCount,
);
