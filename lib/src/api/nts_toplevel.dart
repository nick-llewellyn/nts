// Top-level entry points for package:nts.
//
// Part of the nts.dart library; see that file for the imports,
// re-exports, and defaults these declarations rely on.

part of 'nts.dart';

/// Run a complete authenticated NTPv4 exchange against `spec`.
///
/// On the first call (or after the cookie pool is exhausted) this
/// performs a full NTS-KE handshake before sending the NTPv4 request;
/// subsequent calls reuse the cached AEAD keys and spend a stored
/// cookie.
///
/// `timeout` is a single global wall-clock budget that spans DNS,
/// NTS-KE (TCP connect, TLS handshake, record I/O) and the AEAD-NTPv4
/// UDP exchange as one shrinking deadline. Defaults to
/// [kDefaultTimeout] when omitted.
///
/// `dnsConcurrencyCap` is a per-call ceiling on the process-wide bounded
/// DNS resolver: if the global in-flight counter has already reached
/// this value when the call attempts a lookup, the call short-circuits
/// with [NtsError.timeout] instead of spawning another worker thread.
/// Defaults to [kDefaultDnsConcurrencyCap] when omitted, which inherits
/// the package's built-in default. Because admission is gated against a
/// single process-wide counter, every admitted worker counts toward
/// every caller's threshold, and admission for a given call compares the
/// live pool size against that call's own cap with no awareness of which
/// caller's workers fill the pool. Starvation between mixed-cap callers
/// is therefore **asymmetric**. Concretely: if a `dnsConcurrencyCap: 32`
/// caller already has 4 lookups in flight, a concurrent
/// `dnsConcurrencyCap: 4` caller is refused immediately with
/// [NtsError.timeout] ([TimeoutPhase.dnsSaturation]) even though it has
/// started no lookups of its own — its cap is already met by the other
/// caller's workers. The reverse cannot happen: the low-cap caller's own
/// workers can never push the pool past 4, so they cannot by themselves
/// block the high-cap caller. See `ARCHITECTURE.md`'s "Timeout budget
/// and bounded DNS" section for the full mechanic.
///
/// **Worker-pool occupancy and the bridge admission gate.** Although
/// this wrapper is `async`, the underlying Rust call is a blocking
/// network exchange dispatched to the `flutter_rust_bridge` worker
/// pool: each in-flight call pins one pool thread for its full
/// duration — up to `timeout` in the worst case. The default pool
/// holds one thread per logical CPU, so a burst of concurrent cold
/// queries against many *distinct* hosts could otherwise occupy every
/// worker and stall unrelated bridge calls behind them until a thread
/// frees. To bound that burst, dispatch runs behind an isolate-wide
/// FIFO admission gate: `bridgeConcurrencyCap` (default
/// [kDefaultBridgeConcurrencyCap]) caps how many of this package's
/// calls occupy bridge workers at once, and calls beyond the cap
/// queue on the Dart side — holding no worker thread — until a slot
/// frees. The gate's state is isolate-local: each isolate gates its
/// own calls independently, while the FRB worker pool they land on
/// is shared process-wide, so a multi-isolate app's combined
/// occupancy is bounded by the sum of each isolate's cap, not by one
/// cap. Queue wait is charged against `timeout`: the budget
/// forwarded to the Rust pipeline shrinks by the time spent queued,
/// so the caller's total wall-clock budget stays honest, and a call
/// whose whole budget elapses while queued fails with
/// [NtsError.timeout] ([TimeoutPhase.bridgeSaturation]) without ever
/// dispatching. Admission compares the live in-flight count against
/// each call's own cap — the same asymmetric mixed-cap semantics
/// documented for `dnsConcurrencyCap` above — with one FIFO
/// refinement: a queued call is only overtaken by a later call whose
/// larger cap admits it while the queued call's own cap does not.
/// Concurrent calls against the *same* `host:port` are less of a
/// concern even at the cap: a per-key singleflight on the Rust side
/// collapses them onto one NTS-KE handshake, so their combined
/// wall-clock is bounded by a single exchange (each admitted call
/// still holds its own worker thread while parked, but only until the
/// shared handshake resolves). The gate is independent of
/// `dnsConcurrencyCap`, which bounds DNS resolver threads, not bridge
/// workers — and the two caps compose rather than conflict. With the
/// bridge cap at or below the DNS cap (the defaults are both 4), the
/// package's live calls alone can never saturate the DNS pool; only
/// detached lookups leaked by earlier timed-out calls still consume
/// DNS slots, which is exactly the accumulation the DNS cap exists
/// to bound. Raising `bridgeConcurrencyCap` *above*
/// `dnsConcurrencyCap` re-exposes the DNS gate's fail-fast: admitted
/// distinct-host calls that overlap in their DNS phase beyond the
/// DNS cap are refused immediately with
/// [TimeoutPhase.dnsSaturation] rather than queueing. That skew
/// suits same-host-heavy workloads (singleflight collapses their
/// lookups); for high distinct-host fan-out, raise both caps
/// together. The inverse skew — bridge cap below DNS cap — is always
/// safe: the extra DNS headroom simply goes unused.
///
/// The returned [NtsTimeSample] exposes the raw protocol primitives,
/// not a finished synchronized clock. `utcUnixMicros` is the server
/// transmit timestamp exactly as it appeared on the wire; it does not
/// include any compensation for the one-way network delay between the
/// server and this caller. To approximate the server's clock at the
/// moment the reply arrived, callers should add half the network
/// delay to `utcUnixMicros` (the standard NTP assumption of a
/// symmetric path). The best delay estimate is `peerDelayMicros` (the
/// RFC 5905 peer delay δ, which excludes server processing time) when
/// it is plausible — inside `(0, roundTripMicros]` — falling back to
/// `roundTripMicros` otherwise. For high-precision synchronization,
/// take a burst of samples and pick the one with the smallest such
/// delay before applying that adjustment; this is exactly what the
/// one-call [ntsGetTime] convenience does.
///
/// All arguments (`spec.port`, `timeout`, `dnsConcurrencyCap`,
/// `bridgeConcurrencyCap`) are validated against the FFI encoding range
/// (`1..65535` for the port, 1 ms..4294967295 ms for the timeout,
/// `1..4294967295` for the `u32`-shaped caps; `bridgeConcurrencyCap`
/// never crosses the FFI boundary but is held to the same range for
/// symmetry) before any FFI dispatch; out-of-range values cause the
/// returned `Future` to complete with [NtsError.invalidSpec] without
/// reaching the Rust boundary, on the same `await`/`catch` shape as
/// every other failure mode this wrapper surfaces.
///
/// The FFI boundary carries time at millisecond resolution, so the
/// microsecond precision of the typed parameters does not survive
/// dispatch: a `timeout` with a sub-millisecond component is rounded
/// **up** to the next whole millisecond (the budget is never shortened
/// by conversion), and a `verificationTime` with sub-millisecond
/// precision is **truncated** to whole milliseconds since the Unix
/// epoch. Neither loss is observable in practice — the wire protocol
/// and certificate validity windows operate at far coarser
/// granularity — but callers deriving these values arithmetically
/// should not expect microseconds to round-trip.
///
/// `verificationTime`, when non-null, overrides the timestamp used to
/// check the NTS-KE server certificate's validity window
/// (`notBefore`/`notAfter`) — interpreted in UTC (a non-UTC `DateTime`
/// is converted). It exists to break the cold-start clock-skew
/// deadlock: a
/// device whose real-time clock is badly wrong (factory reset, dead RTC
/// battery, never-set clock) cannot complete the NTS-KE TLS handshake
/// because the certificate is judged expired or not-yet-valid against
/// the skewed clock — yet NTS-KE is the very mechanism that would fix
/// the clock. Supplying a trusted timestamp here (for example a
/// build-baked "this binary cannot predate X" floor) pins the temporal
/// check to that instant while leaving chain-of-trust, hostname, and
/// signature validation fully intact: an untrusted issuer, a hostname
/// mismatch, or a bad signature still fails. When omitted (the default)
/// the system clock is used, exactly as in every prior release.
/// Pre-epoch instants are rejected with [NtsError.invalidSpec] before
/// dispatch.
///
/// Throws an [NtsError] on every failure path.
Future<NtsTimeSample> ntsQuery({
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
    await ffi.ntsQuery(
      spec: ffiSpec,
      timeoutMs: ffiTimeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
      verificationTimeMs: ffiVerificationMs,
    ),
  ),
);

/// One-call "give me the correct time" convenience built on
/// [ntsWarmCookies] + a burst of [ntsQuery] calls against the
/// process-wide default client.
///
/// Runs the recipe the lower-level dartdoc describes by hand: force a
/// fresh NTS-KE handshake to fill the cookie pool, take up to
/// `min(8, freshCookies)` serial authenticated NTPv4 samples, pick
/// the one with the lowest network delay (the RFC 5905 peer delay δ,
/// which excludes server processing time, falling back to the
/// locally measured round trip when δ is implausible), and apply the
/// standard symmetric-path compensation (`utc + delay / 2`). The
/// winning instant is projected onto a monotonic anchor and returned
/// as an [NtsSyncedTime] — which also carries the burst's RFC 5905
/// statistics ([NtsSyncedTime.offsetMicros],
/// [NtsSyncedTime.jitterMicros], [NtsSyncedTime.errorBoundMicros]) —
/// whose [NtsSyncedTime.utcNow] projection is immune to later system
/// clock changes.
///
/// The burst is serial **by design**, not as an implementation
/// shortcut: firing samples concurrently at one server would send
/// them down the same path as a dense cluster sharing any transient
/// queue spike, defeating the lowest-delay selection. Sequential
/// queries let the local interface queue drain between samples so
/// each observes an independent snapshot of the path. Parallelism
/// across *distinct servers* remains legitimate — concurrent
/// `getTime` calls (e.g. for redundancy or server selection) run
/// independently, bounded by the bridge admission gate documented on
/// [ntsQuery].
///
/// Tuning is fixed and internal — the call takes no configuration
/// beyond `spec`, the trust-policy pair (`trustMode` /
/// `customRoots`), and `verificationTime`. The internal values are
/// sized to serve phones and desktops alike: an 8-sample burst for a
/// tight lowest-delay selection, one **total** 8-second budget
/// shared across the handshake and every burst query as a single
/// shrinking deadline (generous enough for a cold-radio cellular
/// handshake plus the full serial burst; effectively free on fast
/// paths, where the call returns as soon as the burst completes),
/// and the package-default concurrency caps
/// ([kDefaultDnsConcurrencyCap] / [kDefaultBridgeConcurrencyCap])
/// forwarded to every underlying call. Deployments that need
/// different numbers compose [ntsWarmCookies] + [ntsQuery] directly;
/// this convenience path deliberately trades configurability for a
/// zero-decision call.
///
/// That budget is metered on a **sleep-aware** monotonic clock, so it
/// keeps depleting while the device is suspended: a call that sleeps
/// mid-flight resumes with the suspended interval already charged and
/// may find the budget spent. Each underlying call receives only the
/// balance remaining when it dispatches, and a balance that has
/// fallen below the 1ms floor the lower-level wrappers accept is
/// **refused rather than rounded up** — the call fails with the
/// synthetic [NtsError.timeout] described below instead of
/// dispatching protocol work on a budget it does not have. A
/// consequence worth relying on: a call refused this way leaves no
/// trace, since the handshake that would replace the cached session
/// for `spec` never runs.
///
/// Error posture is best-effort across the burst: individual burst
/// query failures are tolerated, and the call succeeds if **at least
/// one** sample lands ([NtsSyncedTime.samplesUsed] reports how many
/// did). The call throws only when no sample can be produced:
///
/// - the warming handshake fails — its [NtsError] propagates as-is;
/// - every burst query fails — the **last** query's [NtsError]
///   propagates (with its original stack trace). This includes a
///   query that dispatched and then timed out: its own
///   [NtsError.timeout] is the error that surfaces, not the
///   synthetic one below;
/// - the handshake delivers zero cookies — [NtsError.noCookies];
/// - the budget is exhausted before anything can **dispatch** — a
///   synthetic [NtsError.timeout] with [TimeoutPhase.ntp]. This
///   covers exhaustion before the handshake (only reachable when a
///   suspend lands in the instant between the budget starting and
///   the handshake dispatching) as well as the ordinary case of
///   exhaustion after the handshake but before the first query. The
///   phase names the UDP exchange the budget ran out in front of in
///   both cases; [NtsError.timeout] carries no `trustBackend` in the
///   pre-handshake case, since no handshake ran to attribute one.
///
/// `trustMode` selects the trust-anchor policy applied to the warming
/// handshake and defaults to [TrustMode.platformWithFallback] — the
/// process-wide default client's policy, preserving prior behaviour
/// exactly. Passing any other mode (or a non-null `customRoots`)
/// routes the whole warm+burst flow through a private, call-scoped
/// [NtsClient] constructed with the requested policy; its native
/// handle is disposed before the call returns. This is sound on this
/// path specifically because the call always begins with a forced
/// fresh handshake and spends only the cookies that handshake just
/// minted — there is no cache-reuse window in which a session
/// established under a different policy could be served. The
/// per-mode semantics (`platformOnly` refusing the silent
/// `webpki-roots` downgrade, `bundledOnly` bypassing the platform
/// store, `custom` trusting only the caller-supplied roots) and the
/// accepted `customRoots` encodings (PEM bundle or single DER
/// certificate) are documented on the [NtsClient] constructor. Pair
/// validation matches that constructor too: a non-null `customRoots`
/// requires [TrustMode.custom], and [TrustMode.custom] requires a
/// non-empty `customRoots`; violations complete the returned
/// `Future` with [NtsError.invalidSpec] before any FFI dispatch. Calls
/// routed through the call-scoped client do not update the default
/// singleton's [ntsTrustStatus] counters (same as any explicit
/// [NtsClient] today); read [NtsSyncedTime.trustBackend] for
/// per-call attribution.
///
/// `verificationTime` carries the same cold-start clock-skew-rescue
/// semantics documented on [ntsQuery] and is forwarded to every
/// underlying call. All arguments are validated up front on the same
/// terms as [ntsQuery] (out-of-range values surface as
/// [NtsError.invalidSpec] before any FFI dispatch).
///
/// State effects match calling the two lower-level functions yourself:
/// with the default trust policy the handshake replaces any cached
/// session for `spec` in the process-wide default client's table, and
/// each burst query spends one of the newly delivered cookies. With a
/// non-default policy the session lives in the call-scoped client's
/// table instead and is discarded with it; the default client's table
/// is left untouched.
Future<NtsSyncedTime> ntsGetTime({
  required NtsServerSpec spec,
  TrustMode trustMode = TrustMode.platformWithFallback,
  List<int>? customRoots,
  DateTime? verificationTime,
}) async {
  // Validate ahead of the branch below so an out-of-range spec is
  // reported before the pair-validation the NtsClient factory would
  // raise first. `_getTimeFor` re-runs the same checks on both paths.
  _validateGetTime(
    spec: spec,
    verificationTimeMs: _verificationMs(verificationTime),
  );
  if (trustMode != TrustMode.platformWithFallback || customRoots != null) {
    // Non-default policy: run the whole warm+burst against a private,
    // call-scoped client so the singleton's session table (and its
    // construction-time policy invariant) is never touched. The
    // NtsClient factory owns the trustMode/customRoots pair
    // validation, so the two surfaces cannot drift. Disposing the
    // native handle eagerly releases the throwaway session table
    // rather than waiting for the GC finalizer.
    final client = NtsClient(trustMode: trustMode, customRoots: customRoots);
    try {
      return await _getTimeFor(
        spec: spec,
        verificationTime: verificationTime,
        client: client,
      );
    } finally {
      client._dispose();
    }
  }
  return _getTimeFor(spec: spec, verificationTime: verificationTime);
}

/// Force a fresh NTS-KE handshake against `spec` and return the cookie
/// count along with the per-phase wall-clock breakdown of the handshake.
/// Replaces any cached session for that spec.
///
/// `timeout`, `dnsConcurrencyCap`, and `bridgeConcurrencyCap` carry
/// the same semantics as on [ntsQuery] and default to
/// [kDefaultTimeout] / [kDefaultDnsConcurrencyCap] /
/// [kDefaultBridgeConcurrencyCap] when omitted.
///
/// The worker-pool occupancy mechanics and bridge admission gate
/// documented on [ntsQuery] apply here on identical terms: each
/// dispatched call pins one `flutter_rust_bridge` worker thread for up
/// to `timeout`, and the same isolate-wide gate bounds concurrent
/// dispatch (queue wait charged against `timeout`, saturation
/// surfaced as [TimeoutPhase.bridgeSaturation]) when warming many
/// distinct hosts concurrently.
///
/// The returned [NtsWarmCookiesOutcome.phaseTimings] only covers the
/// KE pipeline (DNS, connect, TLS, KE record I/O); there is no UDP
/// NTP exchange on this path. There is no [TimeoutPhase.ntp]-tagged
/// field on [PhaseTimings] in the first place — [PhaseTimings] only
/// names the four pre-NTP phases — so "implicitly zero" here is
/// shorthand for "the UDP send/recv leg never ran on this code path."
///
/// All arguments are validated against the FFI encoding range
/// before dispatch on the same terms as [ntsQuery]; out-of-range values
/// cause the returned `Future` to complete with [NtsError.invalidSpec]
/// without reaching the Rust boundary.
///
/// `verificationTime` carries the identical clock-skew-rescue
/// semantics described on [ntsQuery]: when non-null it pins the TLS
/// certificate validity-window check to the supplied instant
/// (interpreted in UTC) instead of the system clock, leaving all other
/// certificate validation intact. Pre-epoch instants are rejected with
/// [NtsError.invalidSpec] before dispatch.
///
/// Throws an [NtsError] on every failure path.
Future<NtsWarmCookiesOutcome> ntsWarmCookies({
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
    await ffi.ntsWarmCookies(
      spec: ffiSpec,
      timeoutMs: ffiTimeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
      verificationTimeMs: ffiVerificationMs,
    ),
  ),
);

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
NtsDnsPoolStats ntsDnsPoolStats() =>
    _syncGuard(() => _publicStats(ffi.ntsDnsPoolStats()));

/// Snapshot the process-global trust-anchor diagnostic state.
/// Synchronous (no future / isolate hop): backed by seven atomic
/// loads, cheap enough to call from a UI poll loop or a pre-flight
/// "can I even validate against the platform store?" check.
///
/// Requires `await NtsRustLib.init()` to have completed on the calling
/// isolate before invocation: the seven atomic reads happen on the
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
/// Returns seven observables that callers cannot recover from a
/// per-query [NtsTimeSample] alone:
///
/// 1. `defaultClientBackend` — backend the *default singleton*
///    [NtsClient] (used by [ntsQuery] and [ntsWarmCookies]) most
///    recently resolved to. `null` when no handshake has run yet
///    against the singleton. This is an overwrite-on-store event
///    marker, not a steady-state signal: a transient
///    `webpkiRoots`-resolving handshake latches this field
///    permanently until the next `platform`-resolving one. Use the
///    four counters in (2)–(5) for dashboard panels that need
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
/// 5. `defaultBackendCustomCount` — cumulative count of singleton
///    handshakes that resolved to [TrustBackend.custom]. The
///    default singleton is constructed with
///    [TrustMode.platformWithFallback] and never resolves to
///    `custom`, so in practice this stays zero; it completes the
///    per-backend partition for symmetry.
/// 6. `androidPlatformInitSucceeded` — `true` iff the Android JNI
///    bootstrap reported success at least once. `false` on every
///    other platform.
/// 7. `androidHybridFallbackCount` — cumulative count of TLS chains
///    the Android hybrid verifier has accepted via the
///    `webpki-roots` fallback path. Always zero on non-Android
///    platforms.
///
/// Per-counter monotonicity holds across consecutive snapshots; the
/// snapshot is intended for human / dashboard consumption, not for
/// cross-thread synchronisation. Cross-counter invariants within a
/// single snapshot do not hold — the sum of the four
/// `defaultBackend*Count` fields can be observed to lag the
/// [NtsTrustStatus.defaultClientBackend] pointer by a single
/// store-pair across concurrent snapshots.
NtsTrustStatus ntsTrustStatus() =>
    _syncGuard(() => _publicTrustStatus(ffi.ntsTrustStatus()));
