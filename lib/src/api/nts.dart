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
//    (`kDefaultTimeout`, `kDefaultDnsConcurrencyCap`).
// 2. Type shape: the FFI DTOs use FRB-specific types like
//    `PlatformInt64` and a freezed-generated `NtsError`. Converting to
//    plain Dart `int` and a hand-written sealed `NtsError` at this
//    boundary means a Rust-side struct rename or reorder no longer
//    becomes a Dart source break for downstream callers.
//
// See `ARCHITECTURE.md`'s "Public API stability layer" section for
// the full rationale.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64, PlatformInt64Util;
import '../ffi/api/nts.dart' as ffi;
import 'errors.dart';
import 'models.dart';

export 'errors.dart';
export 'models.dart';

/// Default per-call wall-clock budget for [ntsQuery] / [ntsWarmCookies]
/// / [NtsClient.query] / [NtsClient.warmCookies].
///
/// Sized to cover one DNS lookup plus the NTS-KE TLS 1.3 handshake plus
/// the NTPv4 UDP round-trip against a public server over a typical
/// consumer network, while still failing fast against an unreachable
/// host. Centralising the constant gives callers a stable name to refer
/// to "the package's tuned default" rather than hardcoding the number.
/// Override per-call by passing an explicit `timeout` argument; values
/// must lie between 1 ms and 4294967295 ms (the FFI encoding range,
/// validated at the wrapper boundary).
const Duration kDefaultTimeout = Duration(milliseconds: 5000);

/// Deprecated alias for [kDefaultTimeout], expressed in milliseconds.
///
/// The literal 5000 mirrors `kDefaultTimeout.inMilliseconds`; the getter
/// is an instance member and never const-usable, so it cannot be
/// referenced here.
@Deprecated('Use kDefaultTimeout instead.')
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

/// Default per-call ceiling on concurrently dispatched bridge calls,
/// applied isolate-wide by [ntsQuery] / [ntsWarmCookies] /
/// [NtsClient.query] / [NtsClient.warmCookies] (the gate's state is
/// Dart-side and isolate-local; each isolate gates its own calls over
/// the shared process-wide `flutter_rust_bridge` worker pool).
///
/// Each in-flight call pins one `flutter_rust_bridge` worker thread
/// (a fixed pool of one thread per logical CPU by default) for its
/// full duration — up to `timeout` in the worst case — so an
/// unbounded distinct-host fan-out could occupy every worker and
/// stall unrelated bridge calls behind it. The cap bounds how many of
/// this package's calls occupy workers at once; calls beyond it queue
/// on the Dart side (holding no worker thread) and fail with
/// [NtsError.timeout] ([TimeoutPhase.bridgeSaturation]) if the whole
/// `timeout` budget elapses before a slot frees. Sized to the
/// smallest common mobile pool (4 logical CPUs) so even a saturating
/// burst cannot occupy more workers than the smallest pool holds.
/// Raise per-call on hosts with more headroom by passing an explicit
/// `bridgeConcurrencyCap` argument; values must lie in
/// `1..4294967295`, validated at the wrapper boundary for symmetry
/// with `dnsConcurrencyCap` even though this cap never crosses the
/// FFI boundary.
const int kDefaultBridgeConcurrencyCap = 4;

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
/// [kDefaultTimeout] when omitted. The deprecated `timeoutMs` carries
/// the same budget as raw milliseconds; providing it alongside an
/// explicit non-default `timeout` is rejected with
/// [NtsError.invalidSpec].
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
/// moment the reply arrived, callers should add `roundTripMicros / 2`
/// to `utcUnixMicros` (the standard NTP assumption of a symmetric
/// path). For high-precision synchronization, take a burst of samples
/// and pick the one with the smallest `roundTripMicros` before applying
/// that adjustment.
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
/// dispatch. The deprecated `verificationTimeMs` carries the same
/// instant as milliseconds since the Unix epoch; providing both
/// parameters is rejected with [NtsError.invalidSpec].
///
/// Throws an [NtsError] on every failure path.
Future<NtsTimeSample> ntsQuery({
  required NtsServerSpec spec,
  Duration timeout = kDefaultTimeout,
  @Deprecated('Use timeout instead.') int? timeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
  int bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap,
  DateTime? verificationTime,
  @Deprecated('Use verificationTime instead.') int? verificationTimeMs,
}) => _dispatch(
  spec: spec,
  timeout: timeout,
  timeoutMs: timeoutMs,
  dnsConcurrencyCap: dnsConcurrencyCap,
  bridgeConcurrencyCap: bridgeConcurrencyCap,
  verificationTime: verificationTime,
  verificationTimeMs: verificationTimeMs,
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
/// the one with the lowest round-trip time, and apply the standard
/// symmetric-path compensation (`utc + roundTrip / 2`). The winning
/// instant is projected onto a monotonic anchor and returned as an
/// [NtsSyncedTime], whose [NtsSyncedTime.utcNow] projection is
/// immune to later system clock changes.
///
/// The burst is serial **by design**, not as an implementation
/// shortcut: firing samples concurrently at one server would send
/// them down the same path as a dense cluster sharing any transient
/// queue spike, defeating the lowest-RTT selection. Sequential
/// queries let the local interface queue drain between samples so
/// each observes an independent snapshot of the path. Parallelism
/// across *distinct servers* remains legitimate — concurrent
/// `getTime` calls (e.g. for redundancy or server selection) run
/// independently, bounded by the bridge admission gate documented on
/// [ntsQuery].
///
/// Tuning is fixed and internal — the call takes no configuration
/// beyond `spec` and `verificationTime`. The internal values are
/// sized to serve phones and desktops alike: an 8-sample burst for a
/// tight lowest-RTT selection, one **total** 8-second wall-clock
/// budget shared across the handshake and every burst query as a
/// single shrinking deadline (generous enough for a cold-radio
/// cellular handshake plus the full serial burst; effectively free
/// on fast paths, where the call returns as soon as the burst
/// completes), and the package-default concurrency caps
/// ([kDefaultDnsConcurrencyCap] / [kDefaultBridgeConcurrencyCap])
/// forwarded to every underlying call. Deployments that need
/// different numbers compose [ntsWarmCookies] + [ntsQuery] directly;
/// this convenience path deliberately trades configurability for a
/// zero-decision call.
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
/// - the budget is exhausted after the handshake before the first
///   query can even **dispatch** — a synthetic [NtsError.timeout]
///   with [TimeoutPhase.ntp] (the UDP exchange is the phase the
///   budget ran out in front of).
///
/// `verificationTime` (or the deprecated `verificationTimeMs`) carries
/// the same cold-start clock-skew-rescue semantics documented on
/// [ntsQuery] and is forwarded to every
/// underlying call. All arguments are validated up front on the same
/// terms as [ntsQuery] (out-of-range values surface as
/// [NtsError.invalidSpec] before any FFI dispatch).
///
/// State effects match calling the two lower-level functions yourself:
/// the handshake replaces any cached session for `spec` in the
/// process-wide default client's table, and each burst query spends
/// one of the newly delivered cookies.
Future<NtsSyncedTime> ntsGetTime({
  required NtsServerSpec spec,
  DateTime? verificationTime,
  @Deprecated('Use verificationTime instead.') int? verificationTimeMs,
}) async {
  final resolvedVerificationMs = _resolveVerificationTime(
    verificationTime,
    verificationTimeMs,
  );
  _validateGetTime(spec: spec, verificationTimeMs: resolvedVerificationMs);
  return _getTime(
    warm: (timeout) => ntsWarmCookies(
      spec: spec,
      timeout: timeout,
      dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
      bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
      verificationTime: _verificationInstant(resolvedVerificationMs),
    ),
    query: (timeout) => ntsQuery(
      spec: spec,
      timeout: timeout,
      dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
      bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
      verificationTime: _verificationInstant(resolvedVerificationMs),
    ),
  );
}

/// Force a fresh NTS-KE handshake against `spec` and return the cookie
/// count along with the per-phase wall-clock breakdown of the handshake.
/// Replaces any cached session for that spec.
///
/// `timeout`, `dnsConcurrencyCap`, and `bridgeConcurrencyCap` carry
/// the same semantics as on [ntsQuery] and default to
/// [kDefaultTimeout] / [kDefaultDnsConcurrencyCap] /
/// [kDefaultBridgeConcurrencyCap] when omitted. The deprecated
/// `timeoutMs` resolves on the same terms as on [ntsQuery].
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
/// [NtsError.invalidSpec] before dispatch, and providing both
/// `verificationTime` and the deprecated `verificationTimeMs` is
/// rejected on the same terms as [ntsQuery].
///
/// Throws an [NtsError] on every failure path.
Future<NtsWarmCookiesOutcome> ntsWarmCookies({
  required NtsServerSpec spec,
  Duration timeout = kDefaultTimeout,
  @Deprecated('Use timeout instead.') int? timeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
  int bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap,
  DateTime? verificationTime,
  @Deprecated('Use verificationTime instead.') int? verificationTimeMs,
}) => _dispatch(
  spec: spec,
  timeout: timeout,
  timeoutMs: timeoutMs,
  dnsConcurrencyCap: dnsConcurrencyCap,
  bridgeConcurrencyCap: bridgeConcurrencyCap,
  verificationTime: verificationTime,
  verificationTimeMs: verificationTimeMs,
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
NtsDnsPoolStats ntsDnsPoolStats() => _publicStats(ffi.ntsDnsPoolStats());

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
  /// alongside a non-empty byte sequence in [customRoots] — either a
  /// PEM-encoded certificate bundle (one or more
  /// `-----BEGIN CERTIFICATE-----` blocks, optionally preceded by a
  /// PKCS7-style "Bag Attributes" / "subject=" preamble) or a single
  /// DER-encoded certificate's raw bytes — to trust only those
  /// caller-supplied custom root certificates. The choice is
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
  /// Parameter semantics for `timeout`, `dnsConcurrencyCap`,
  /// `bridgeConcurrencyCap`, and `verificationTime` (plus the
  /// deprecated `timeoutMs` / `verificationTimeMs`) are identical
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
    @Deprecated('Use timeout instead.') int? timeoutMs,
    int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
    int bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap,
    DateTime? verificationTime,
    @Deprecated('Use verificationTime instead.') int? verificationTimeMs,
  }) => _dispatch(
    spec: spec,
    timeout: timeout,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTime: verificationTime,
    verificationTimeMs: verificationTimeMs,
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
    @Deprecated('Use timeout instead.') int? timeoutMs,
    int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
    int bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap,
    DateTime? verificationTime,
    @Deprecated('Use verificationTime instead.') int? verificationTimeMs,
  }) => _dispatch(
    spec: spec,
    timeout: timeout,
    timeoutMs: timeoutMs,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTime: verificationTime,
    verificationTimeMs: verificationTimeMs,
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
  /// `freshCookies`, one total 8-second shared budget, lowest-RTT
  /// selection with `roundTrip / 2` compensation, best-effort success
  /// when at least one sample lands). The only difference is state
  /// scope: the handshake replaces the cached session for `spec` in
  /// **this client's** table, and the burst spends this client's
  /// cookies, leaving the process-wide default client untouched.
  Future<NtsSyncedTime> getTime({
    required NtsServerSpec spec,
    DateTime? verificationTime,
    @Deprecated('Use verificationTime instead.') int? verificationTimeMs,
  }) async {
    final resolvedVerificationMs = _resolveVerificationTime(
      verificationTime,
      verificationTimeMs,
    );
    _validateGetTime(spec: spec, verificationTimeMs: resolvedVerificationMs);
    return _getTime(
      warm: (timeout) => warmCookies(
        spec: spec,
        timeout: timeout,
        dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
        bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
        verificationTime: _verificationInstant(resolvedVerificationMs),
      ),
      query: (timeout) => query(
        spec: spec,
        timeout: timeout,
        dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
        bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
        verificationTime: _verificationInstant(resolvedVerificationMs),
      ),
    );
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
// FFI-bound integer arguments hit FRB-generated `sse_encode_u_16` /
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
// futile FFI hop. `timeout` (in milliseconds) and `dnsConcurrencyCap`
// are restricted to `1..0xFFFFFFFF`: zero used to be a sentinel for
// "inherit the Rust-side default" in 1.x and 3.0.x, but consumers are
// now steered toward the named `kDefault*` constants which expose the
// actual values. `bridgeConcurrencyCap` never crosses the FFI
// boundary (the gate is pure Dart), but it is held to the same
// `1..0xFFFFFFFF` range so the three cap/budget parameters share one
// validation contract.

const int _kU32Max = 0xFFFFFFFF;

// --- deprecated-parameter resolution ----------------------------------
//
// One release of overlap: the deprecated `int` millisecond parameters
// coexist with the typed `Duration` / `DateTime` ones. These helpers
// collapse each pair onto the single value the rest of the pipeline
// uses, failing fast on any *detectable* conflict.

// `timeout` has a non-null default, so an un-migrated caller passing
// only `timeoutMs` necessarily leaves `timeout` at `kDefaultTimeout` —
// that is the silent compatibility path. An explicit non-default
// `timeout` alongside `timeoutMs` is a demonstrable conflict and is
// rejected. Known blind spot (accepted): `Duration` equality is
// value-based, so any explicit `timeout` equal to [kDefaultTimeout]
// (the constant itself or e.g. `Duration(seconds: 5)`) passed alongside
// `timeoutMs` is indistinguishable from the default case and resolves
// to `timeoutMs` without error.
Duration _resolveTimeout(Duration timeout, int? timeoutMs) {
  if (timeoutMs == null) return timeout;
  if (timeout == kDefaultTimeout) return Duration(milliseconds: timeoutMs);
  throw const NtsError.invalidSpec(
    message:
        'both timeout and the deprecated timeoutMs were provided with '
        'conflicting values; pass one or the other (prefer timeout)',
  );
}

// Both verification parameters are nullable with no default, so "both
// supplied" is an unambiguous caller mistake rather than a
// default-vs-override situation. The resolved value stays an epoch-ms
// `int?` internally (the FFI shape).
int? _resolveVerificationTime(DateTime? verificationTime, int? ms) {
  if (verificationTime != null && ms != null) {
    throw const NtsError.invalidSpec(
      message:
          'both verificationTime and the deprecated verificationTimeMs '
          'were provided; pass one or the other (prefer verificationTime)',
    );
  }
  return verificationTime?.toUtc().millisecondsSinceEpoch ?? ms;
}

// Re-wraps a resolved epoch-ms verification instant as a UTC `DateTime`
// for forwarding through the non-deprecated parameter of the underlying
// wrappers (used by the getTime orchestration entry points).
DateTime? _verificationInstant(int? resolvedMs) => resolvedMs == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(resolvedMs, isUtc: true);

// Shared resolve -> validate -> gate -> convert -> catch scaffolding
// for the four query/warmCookies entry points (top-level and
// per-client). Each entry point supplies only its own FFI invocation
// via `call`, receiving the already-converted FFI-shaped arguments.
Future<T> _dispatch<T>({
  required NtsServerSpec spec,
  required Duration timeout,
  required int? timeoutMs,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  required DateTime? verificationTime,
  required int? verificationTimeMs,
  required Future<T> Function(
    ffi.NtsServerSpec ffiSpec,
    int ffiTimeoutMs,
    PlatformInt64? ffiVerificationMs,
  )
  call,
}) async {
  final resolvedTimeout = _resolveTimeout(timeout, timeoutMs);
  final resolvedVerificationMs = _resolveVerificationTime(
    verificationTime,
    verificationTimeMs,
  );
  _validateRanges(
    spec: spec,
    timeout: resolvedTimeout,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTimeMs: resolvedVerificationMs,
  );
  return _withBridgeSlot(
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    timeout: resolvedTimeout,
    body: (remainingTimeout) async {
      try {
        return await call(
          _ffiSpec(spec),
          _ffiTimeoutMs(remainingTimeout),
          _ffiVerificationTime(resolvedVerificationMs),
        );
      } on ffi.NtsError catch (err, stack) {
        // Preserve the original FFI-side stack trace through the
        // conversion so debuggers point at the FRB dispatcher / Rust
        // boundary where the error originated, not at this catch site.
        Error.throwWithStackTrace(_publicError(err), stack);
      }
    },
  );
}

void _validatePort(NtsServerSpec spec) {
  if (spec.port < 1 || spec.port > 65535) {
    throw NtsError.invalidSpec(
      message: 'port ${spec.port} is outside the valid range 1..65535',
    );
  }
}

void _validateRanges({
  required NtsServerSpec spec,
  required Duration timeout,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  int? verificationTimeMs,
}) {
  _validatePort(spec);
  if (timeout < const Duration(milliseconds: 1) ||
      timeout > const Duration(milliseconds: _kU32Max)) {
    throw NtsError.invalidSpec(
      message:
          'timeout $timeout (or the deprecated timeoutMs) is outside the '
          'valid range 1ms..${_kU32Max}ms — sub-millisecond durations are '
          'rejected (1 ms floor); pass kDefaultTimeout to inherit the '
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
  if (bridgeConcurrencyCap < 1 || bridgeConcurrencyCap > _kU32Max) {
    throw NtsError.invalidSpec(
      message:
          'bridgeConcurrencyCap $bridgeConcurrencyCap is outside the valid '
          'range 1..$_kU32Max; pass kDefaultBridgeConcurrencyCap '
          '($kDefaultBridgeConcurrencyCap) to inherit the package default',
    );
  }
  // The resolved verification instant is an epoch-milliseconds value:
  // the Rust side maps it to a `UnixTime` via `Duration::from_millis(u64)`,
  // so a negative value cannot encode a real instant. Reject it here with
  // the same `invalidSpec` surface as the other range checks rather than
  // letting it silently fall back to the system clock on the Rust side.
  if (verificationTimeMs != null && verificationTimeMs < 0) {
    throw NtsError.invalidSpec(
      message:
          'verificationTime (or the deprecated verificationTimeMs) resolves '
          'to $verificationTimeMs ms, which is before the Unix epoch; it '
          'must be a non-negative epoch-milliseconds instant',
    );
  }
}

// `getTime` validation front-loads the same checks its underlying
// warm/query calls would run, so an invalid argument surfaces as
// `NtsError.invalidSpec` before the warming handshake ever dispatches
// (rather than after a successful handshake has already replaced the
// cached session). The tuning knobs themselves are internal constants
// and need no range check.
void _validateGetTime({required NtsServerSpec spec, int? verificationTimeMs}) {
  _validateRanges(
    spec: spec,
    timeout: _kGetTimeTimeout,
    dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
    bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
    verificationTimeMs: verificationTimeMs,
  );
}

// --- getTime orchestration --------------------------------------------
//
// Shared engine behind the top-level `ntsGetTime` and
// `NtsClient.getTime`. Both entry points bind their own `warm` /
// `query` closures (top-level functions vs. per-client methods) and
// delegate the budget accounting, burst loop, lowest-RTT selection,
// and compensation here so the two surfaces cannot drift.
//
// `_kGetTimeTimeout` is one total budget: a single `Stopwatch`
// started before the handshake meters every underlying call, and each
// call receives only the remaining balance. The lower-level wrappers
// validate `timeout >= 1ms`, so a depleted budget is detected here
// (and surfaced as `timeout(ntp)`) rather than tripping their
// `invalidSpec` range check with a confusing message.

// Upper bound on the number of burst `query` samples taken after the
// warming handshake. The effective burst size is
// `min(_kGetTimeMaxBurst, freshCookies)` — each query spends one
// cookie, so the burst never exhausts the pool it just filled. Eight
// samples give a tight lowest-RTT selection on steady paths and
// enough spread to ride out jitter on cellular / Wi-Fi ones.
const int _kGetTimeMaxBurst = 8;

// Total wall-clock budget for the whole `getTime` call, shared across
// the warming handshake and every burst query as one shrinking
// deadline. Sized for the 8-query burst over a cold-radio cellular
// path (DNS + TCP + TLS + KE handshake plus eight serial UDP
// round-trips); on fast paths the call returns as soon as the burst
// completes, so the generous cap only moves the worst-case failure
// latency, never the happy path.
const Duration _kGetTimeTimeout = Duration(milliseconds: 8000);

Future<NtsSyncedTime> _getTime({
  required Future<NtsWarmCookiesOutcome> Function(Duration timeout) warm,
  required Future<NtsTimeSample> Function(Duration timeout) query,
}) async {
  final budget = Stopwatch()..start();
  // Exact `Duration` subtraction at microsecond resolution. The
  // ms-precision conversion happens once per dispatch, at the FFI
  // boundary (`_ffiTimeoutMs`), which rounds *up* so a live sub-ms
  // remainder is never rounded down to a dead budget. The trade-off:
  // each forwarded ms value may exceed the true remainder by <1 ms
  // (bounded overall to <1 ms on the final dispatch), rather than the
  // pre-Duration shape's strict floor.
  Duration remaining() => _kGetTimeTimeout - budget.elapsed;

  // Warm phase: always a fresh handshake, so the burst below runs
  // against a full cookie pool and a known-fresh AEAD session. A
  // failure here is fatal by design — there is nothing to sample with.
  // The handshake draws from the shared balance too (not a fresh
  // `_kGetTimeTimeout`), so overhead accrued since `budget` started
  // is charged against the total rather than silently extending it.
  // The clamp keeps a fully depleted balance from tripping the
  // lower-level `timeout >= 1ms` validation; a 1ms warm then times
  // out on its own terms and propagates per the posture above.
  const floor = Duration(milliseconds: 1);
  final warmBudget = remaining();
  final outcome = await warm(warmBudget < floor ? floor : warmBudget);
  if (outcome.freshCookies < 1) {
    throw NtsError.noCookies(trustBackend: outcome.trustBackend);
  }

  final burst = math.min(_kGetTimeMaxBurst, outcome.freshCookies);
  NtsTimeSample? best;
  // Monotonic instant (on `budget`'s timeline) at which the current
  // `best` sample's reply arrived. Used below to advance the winning
  // sample's compensated UTC across the remainder of the burst, so
  // the constructed clock is anchored to "now" rather than to the
  // (possibly much earlier) winning recv.
  var bestArrivalMicros = 0;
  var samplesUsed = 0;
  Object? lastError;
  StackTrace? lastStack;
  for (var i = 0; i < burst; i++) {
    final left = remaining();
    if (left < const Duration(milliseconds: 1)) break;
    try {
      final sample = await query(left);
      samplesUsed++;
      if (best == null || sample.roundTripMicros < best.roundTripMicros) {
        best = sample;
        bestArrivalMicros = budget.elapsedMicroseconds;
      }
    } on NtsError catch (err, stack) {
      // Best-effort posture: tolerate individual burst failures as
      // long as at least one sample lands. Keep the most recent
      // failure so an all-fail burst rethrows something concrete.
      lastError = err;
      lastStack = stack;
    }
  }

  if (best == null) {
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack!);
    }
    // No query ever completed and none failed: the budget was spent
    // by the handshake before the first sample could dispatch.
    throw NtsError.timeout(
      phase: TimeoutPhase.ntp,
      trustBackend: outcome.trustBackend,
    );
  }

  // Symmetric-path compensation: the sample's `utcUnixMicros` is the
  // server transmit timestamp as of the reply's *send*; adding half
  // the round trip estimates the server clock at the moment the reply
  // arrived. That estimate is only valid at the winning recv instant,
  // while `NtsSyncedTime` anchors its monotonic stopwatch at
  // construction — which happens after the whole burst has run. Bridge
  // the gap by advancing the compensated UTC across the time elapsed
  // since the winning reply arrived (`anchorLagMicros`), so the value
  // handed to the constructor is valid "now" even when the lowest-RTT
  // sample was not the last query in the burst.
  final anchorLagMicros = budget.elapsedMicroseconds - bestArrivalMicros;
  return NtsSyncedTime(
    utcUnixMicros:
        best.utcUnixMicros + best.roundTripMicros ~/ 2 + anchorLagMicros,
    roundTripMicros: best.roundTripMicros,
    samplesUsed: samplesUsed,
    trustBackend: best.trustBackend,
  );
}

// --- bridge admission gate --------------------------------------------
//
// The four async wrappers dispatch blocking Rust network exchanges to
// the `flutter_rust_bridge` worker pool (a fixed pool of one thread
// per logical CPU by default), and each in-flight call pins one pool
// thread for its full duration — up to `timeout`. This gate bounds
// how many of this package's calls occupy pool threads at once so a
// distinct-host fan-out burst cannot exhaust the pool and stall
// unrelated bridge calls behind it. Waiters queue on the Dart side
// (holding no pool thread) in arrival order; admission compares the
// live in-flight count against each waiter's own
// `bridgeConcurrencyCap`, giving mixed-cap bursts the same asymmetric
// semantics as the Rust-side DNS resolver pool. `_admitBridgeWaiters`
// walks the queue in FIFO order and admits every waiter whose cap
// clears the count, so at rest every queued waiter's cap is <= the
// in-flight count; a new arrival that is admissible therefore never
// jumps a waiter that is also admissible — it only overtakes waiters
// whose smaller caps keep them queued regardless.
//
// Queue wait is charged against the call's `timeout` and only the
// remainder crosses the FFI boundary, keeping the caller's total
// wall-clock budget honest; a budget that expires while queued
// surfaces as `NtsError.timeout(phase: TimeoutPhase.bridgeSaturation)`
// without any FFI dispatch. All state below is confined to the
// calling isolate (the same isolate FRB dispatches from), and every
// mutation happens synchronously between suspension points, so no
// further synchronisation is needed.

class _BridgeWaiter {
  final int cap;
  final Completer<void> admitted = Completer<void>();
  _BridgeWaiter(this.cap);
}

int _bridgeInFlight = 0;
final List<_BridgeWaiter> _bridgeQueue = <_BridgeWaiter>[];

Future<T> _withBridgeSlot<T>({
  required int bridgeConcurrencyCap,
  required Duration timeout,
  required Future<T> Function(Duration remainingTimeout) body,
}) async {
  // Uncontended calls take the slot synchronously and forward
  // `timeout` verbatim; the queue-wait deduction below only applies
  // to calls that actually queued.
  var remainingTimeout = timeout;
  if (_bridgeInFlight < bridgeConcurrencyCap) {
    _bridgeInFlight++;
  } else {
    final queueWait = Stopwatch()..start();
    final waiter = _BridgeWaiter(bridgeConcurrencyCap);
    _bridgeQueue.add(waiter);
    // Captured at enqueue time so the timeout error's stack trace points
    // at the wrapper call path that queued the waiter, not at the timer
    // callback that fired the deadline.
    final enqueueTrace = StackTrace.current;
    final deadline = Timer(timeout, () {
      if (!waiter.admitted.isCompleted) {
        // Completing with the error is also the cancellation mark: the
        // entry stays queued and `_admitBridgeWaiters` drops it during
        // its next compaction pass, keeping a mass-timeout burst O(n)
        // overall instead of the O(n²) a per-timeout `List.remove`
        // (linear search + element shifting) would cost. A queued
        // waiter implies at least one in-flight call, whose release
        // runs that pass, so cancelled entries cannot linger.
        waiter.admitted.completeError(
          const NtsError.timeout(phase: TimeoutPhase.bridgeSaturation),
          enqueueTrace,
        );
      }
    });
    try {
      // `_admitBridgeWaiters` increments `_bridgeInFlight` on this
      // call's behalf before completing the future, so both branches
      // converge holding exactly one slot.
      await waiter.admitted.future;
    } finally {
      deadline.cancel();
    }
    remainingTimeout = timeout - queueWait.elapsed;
  }
  try {
    if (remainingTimeout < const Duration(milliseconds: 1)) {
      // The slot was granted at (or a scheduling beat past) the exact
      // moment the budget ran out; dispatching with a zero budget is
      // indistinguishable from having timed out while queued.
      throw const NtsError.timeout(phase: TimeoutPhase.bridgeSaturation);
    }
    return await body(remainingTimeout);
  } finally {
    _bridgeInFlight--;
    _admitBridgeWaiters();
  }
}

void _admitBridgeWaiters() {
  // Single-pass in-place compaction keeps admission O(n): admitted
  // and timed-out waiters are dropped, retained waiters shift down,
  // and the tail is truncated once — versus the O(n²) element
  // shifting a per-waiter `removeAt` would cost under a large queued
  // burst. Mutating in place is safe: `complete()` only schedules
  // microtasks and the loop has no suspension points, so no timer or
  // waiter continuation can observe the queue mid-compaction.
  var kept = 0;
  for (var i = 0; i < _bridgeQueue.length; i++) {
    final waiter = _bridgeQueue[i];
    if (waiter.admitted.isCompleted) {
      // Timed out while queued: the deadline timer already completed
      // the future with `bridgeSaturation` and left the entry here
      // for this pass to sweep. Drop without admitting.
      continue;
    }
    if (_bridgeInFlight < waiter.cap) {
      _bridgeInFlight++;
      waiter.admitted.complete();
    } else {
      _bridgeQueue[kept++] = waiter;
    }
  }
  _bridgeQueue.length = kept;
}

// --- conversion layer (FFI <-> public) -------------------------------
//
// All FFI types stay scoped to this file. Conversions are intentionally
// total (no fallback / catch-all arms) so a future Rust-side variant
// addition surfaces as an exhaustiveness error here rather than as a
// silently-dropped variant at the consumer.

ffi.NtsServerSpec _ffiSpec(NtsServerSpec spec) =>
    ffi.NtsServerSpec(host: spec.host, port: spec.port);

// `verificationTimeMs` crosses the boundary as the FRB `PlatformInt64`
// (the Rust side is `Option<i64>`). On the native platforms this package
// targets (`web`/`wasm` are excluded — see `pubspec.yaml`) `PlatformInt64`
// is an alias for `int`, so this conversion is an identity; routing
// through `PlatformInt64Util.from` keeps the to-FFI boundary explicit and
// correct independent of the FRB platform mapping, mirroring the
// `.toInt()` calls used in the FFI -> public direction. Negative values
// are rejected by `_validateRanges` before reaching here.
PlatformInt64? _ffiVerificationTime(int? ms) =>
    ms == null ? null : PlatformInt64Util.from(ms);

// Converts a resolved `Duration` budget to the FFI's millisecond `int`
// with a *ceiling*, so a live sub-millisecond remainder is never rounded
// down to a dead (zero) budget at dispatch. The forwarded value may
// exceed the true remainder by <1 ms — see the `_getTime` remaining()
// comment for the budget-accounting consequences.
int _ffiTimeoutMs(Duration d) => (d.inMicroseconds + 999) ~/ 1000;

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
