// Owned client handle for package:nts.
//
// Part of the nts.dart library; see that file for the imports,
// re-exports, and defaults these declarations rely on.

part of 'nts.dart';

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
  /// alongside a non-empty byte sequence in [customRoots] — either a
  /// PEM-encoded certificate bundle (one or more
  /// `-----BEGIN CERTIFICATE-----` blocks, optionally preceded by a
  /// PKCS7-style "Bag Attributes" / "subject=" preamble) or a single
  /// DER-encoded certificate's raw bytes — to trust only those
  /// caller-supplied custom root certificates. The choice is
  /// immutable for the life of the client.
  ///
  /// **`customRoots` ownership.** The list is read, not retained: its
  /// contents are copied on the way to the FFI boundary and the copy
  /// is overwritten with zeros once the native side has consumed it.
  /// Your list is never mutated, and no reference to it outlives this
  /// call — so wiping it afterwards is yours to do if the bytes are
  /// sensitive in your threat model. Do not assume this package wipes
  /// it for you. Trust anchors are public certificates in the common
  /// case; the caution matters for deployments where the anchor set
  /// itself is confidential.
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
    _validateTrustPolicy(trustMode: trustMode, customRoots: customRoots);
    if (trustMode == TrustMode.platformWithFallback) {
      return NtsClient._(ffi.NtsClient());
    }
    // `_ffiTrustMode` copies `customRoots` into the `Uint8List` the FFI
    // encoder needs. The encode is synchronous and complete when
    // `withTrustMode` returns, so the copy is wiped in a `finally` —
    // including on a throw, when the bytes would otherwise be
    // unreachable and unwipeable.
    final ffiMode = _ffiTrustMode(trustMode, customRoots);
    try {
      return NtsClient._(ffi.NtsClient.withTrustMode(trustMode: ffiMode));
    } finally {
      _wipeCustomRoots(ffiMode);
    }
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
  TrustMode get trustMode =>
      _syncGuard(() => _publicTrustMode(_inner.trustMode()));

  /// Per-client equivalent of the top-level [ntsQuery]. The cookie
  /// pool, AEAD keys, and KE session live in this client's table; on
  /// the first call (or after the cookie pool is exhausted) a full
  /// NTS-KE handshake runs, then subsequent calls reuse the cached
  /// session.
  ///
  /// Parameter semantics for `timeout`, `dnsConcurrencyCap`,
  /// `bridgeConcurrencyCap`, and `verificationTime` are identical
  /// to [ntsQuery]; defaults come from [kDefaultTimeout],
  /// [kDefaultDnsConcurrencyCap], and [kDefaultBridgeConcurrencyCap],
  /// and out-of-range values cause the returned `Future` to complete
  /// with [NtsError.invalidSpec] on the same terms as the top-level
  /// wrapper.
  /// `verificationTime` carries the same cold-start clock-skew-rescue
  /// behaviour documented on [ntsQuery]. The [NtsTimeSample] return
  /// shape is identical too — see [ntsQuery]'s dartdoc for the raw
  /// protocol primitives the sample exposes and how to apply the
  /// one-way-delay correction, and for the bridge admission gate,
  /// which applies to this method unchanged: the gate is isolate-wide
  /// and shared with the top-level wrappers and every other client in
  /// the calling isolate (per-client tables do not change which FRB
  /// worker pool the call blocks on).
  ///
  /// Throws an [NtsError] on every failure path.
  Future<NtsTimeSample> query({
    required NtsServerSpec spec,
    Duration timeout = kDefaultTimeout,
    int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
    int bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap,
    DateTime? verificationTime,
  }) => _dispatch(
    spec: spec,
    timeout: timeout,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTime: verificationTime,
    call: (ffiSpec, ffiTimeoutMs, ffiVerificationMs) async => _publicSample(
      await _inner.query(
        spec: ffiSpec,
        timeoutMs: ffiTimeoutMs,
        dnsConcurrencyCap: dnsConcurrencyCap,
        verificationTimeMs: ffiVerificationMs,
      ),
    ),
  );

  /// Per-client equivalent of the top-level [ntsWarmCookies]. Forces
  /// a fresh NTS-KE handshake and ingests the delivered cookie pool
  /// into this client's table, replacing any previously cached
  /// session for the spec.
  ///
  /// All arguments are validated against the FFI encoding
  /// range before dispatch on the same terms as [ntsQuery] /
  /// [ntsWarmCookies]; out-of-range values cause the returned `Future`
  /// to complete with [NtsError.invalidSpec] without reaching the
  /// Rust boundary. `verificationTime` carries the same cold-start
  /// clock-skew-rescue behaviour documented on [ntsQuery], and the
  /// bridge admission gate on [ntsQuery] applies to this method
  /// unchanged (isolate-wide, shared with the top-level wrappers and
  /// every other client in the calling isolate).
  ///
  /// Throws an [NtsError] on every failure path.
  Future<NtsWarmCookiesOutcome> warmCookies({
    required NtsServerSpec spec,
    Duration timeout = kDefaultTimeout,
    int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
    int bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap,
    DateTime? verificationTime,
  }) => _dispatch(
    spec: spec,
    timeout: timeout,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTime: verificationTime,
    call: (ffiSpec, ffiTimeoutMs, ffiVerificationMs) async => _publicWarm(
      await _inner.warmCookies(
        spec: ffiSpec,
        timeoutMs: ffiTimeoutMs,
        dnsConcurrencyCap: dnsConcurrencyCap,
        verificationTimeMs: ffiVerificationMs,
      ),
    ),
  );

  /// Per-client equivalent of the top-level [ntsGetTime]: one-call
  /// synchronized clock built on [warmCookies] + a burst of [query]
  /// calls against this client's own session table.
  ///
  /// Behaviour, parameter semantics, internal tuning, error posture,
  /// and validation are identical to [ntsGetTime] — see its dartdoc
  /// for the full contract (fixed 8-sample serial burst clamped to
  /// `freshCookies`, one total 8-second sleep-aware shared budget
  /// that refuses to dispatch once spent, lowest-delay selection with
  /// `delay / 2` compensation, best-effort success when at least one
  /// sample lands). The differences are state scope and trust policy:
  /// the handshake replaces the cached session for `spec` in **this
  /// client's** table, the burst spends this client's cookies
  /// (leaving the process-wide default client untouched), and the
  /// handshake runs under this client's construction-time trust
  /// policy — there is no per-call `trustMode` parameter here,
  /// because the policy is already a property of the client
  /// ([ntsGetTime]'s `trustMode` / `customRoots` parameters are the
  /// convenience spelling of constructing such a client for one
  /// call).
  Future<NtsSyncedTime> getTime({
    required NtsServerSpec spec,
    DateTime? verificationTime,
  }) =>
      _getTimeFor(spec: spec, verificationTime: verificationTime, client: this);

  /// Drop this client's cached session for `spec`'s `host:port`, if
  /// any. Returns `true` when an entry was removed, `false` when no
  /// session was cached for that key. The next [query] or
  /// [warmCookies] for that spec triggers a fresh NTS-KE handshake.
  ///
  /// Synchronous: backed by one mutex acquisition and one
  /// `HashMap::remove` on the Rust side; no isolate hop. The
  /// wrapper validates `spec` first — a blank host or a port outside
  /// the FRB-encodable range `1..65535` throws
  /// [NtsError.invalidSpec] with a wrapper-authored message before
  /// any FFI dispatch (matching the surface the four async wrappers
  /// expose via [ntsQuery] / [ntsWarmCookies]) rather than
  /// soft-failing as `false`.
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
    _validateSpec(spec);
    return _syncGuard(() => _inner.invalidate(spec: _ffiSpec(spec)));
  }

  /// Drop every cached session in this client's table. Cheap;
  /// intended for test cleanup and for apps that want to release
  /// cached key material at a specific point rather than waiting for
  /// the table's own bounds.
  ///
  /// The table is already bounded on the Rust side — at most 64
  /// sessions, least-recently-used evicted, each dropped once idle
  /// for 24 hours — so [clear] is an eager control, not the only
  /// thing standing between a long-lived process and unbounded
  /// retention of cached keys and cookies.
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
  void clear() => _syncGuard(() => _inner.clear());

  // Release the underlying native handle (the Rust `Arc` behind the
  // FRB `RustOpaque`) eagerly instead of waiting for the GC
  // finalizer. Library-internal: the public surface deliberately
  // exposes no dispose method — long-lived clients are reclaimed by
  // the finalizer, and only the call-scoped client minted inside
  // [ntsGetTime] needs deterministic release. Owning this here keeps
  // any future cleanup for `NtsClient` internals in one place rather
  // than coupling callers to the `_inner` representation.
  void _dispose() => _inner.dispose();
}
