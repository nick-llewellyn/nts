// Hand-written stable surface for `package:nts`.
//
// This file is the public contract consumers see when they
// `import 'package:nts/nts.dart'`. It delegates to the FRB-generated
// bindings in `lib/src/ffi/api/nts.dart` while exposing default-bearing
// optional parameters that are robust to Rust-side signature evolution.
// FRB v2 codegen marks every Rust argument as a `required` named
// parameter on the Dart side; absorbing the asymmetry here means an
// internal regen is no longer a SemVer event for downstream callers.
// See `ARCHITECTURE.md`'s "Public API stability layer" section for the
// full rationale.

import '../ffi/api/nts.dart' as ffi;
import '../ffi/api/nts.dart' show NtsDnsPoolStats, NtsServerSpec, NtsTimeSample;

export '../ffi/api/nts.dart'
    show
        NtsDnsPoolStats,
        NtsServerSpec,
        NtsTimeSample,
        NtsError,
        // The `NtsError_*` variant subclasses are part of the public API:
        // they are the runtime types produced by the FRB-generated
        // freezed sealed class and downstream code needs them in scope
        // to pattern-match exhaustively.
        NtsError_InvalidSpec,
        NtsError_Network,
        NtsError_KeProtocol,
        NtsError_NtpProtocol,
        NtsError_Authentication,
        NtsError_Timeout,
        NtsError_NoCookies,
        NtsError_Internal;

/// Default per-call wall-clock budget, in milliseconds.
///
/// Matches what 1.2.0 callers got when they passed `timeoutMs: 5000`
/// (or, equivalently, `0` to inherit the Rust-side default). Centralising
/// the constant gives callers a stable name to refer to "whatever the
/// package's tuned default is" without hardcoding the number, and gives
/// the package a single edit site if the default ever has to move.
const int kDefaultTimeoutMs = 5000;

/// Default per-call ceiling on in-flight DNS resolver workers.
///
/// `0` is the sentinel that selects the Rust-side default (currently 4,
/// chosen for mobile pthread-stack accumulation budgets — see
/// `rust/src/nts/dns.rs`). Centralising the constant gives callers a
/// stable name to refer to "whatever the package's tuned default is"
/// rather than the literal `0` whose meaning is non-obvious.
const int kDefaultDnsConcurrencyCap = 0;

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
Future<NtsTimeSample> ntsQuery({
  required NtsServerSpec spec,
  int timeoutMs = kDefaultTimeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
}) => ffi.ntsQuery(
  spec: spec,
  timeoutMs: timeoutMs,
  dnsConcurrencyCap: dnsConcurrencyCap,
);

/// Snapshot the bounded DNS resolver pool counters. Synchronous (no
/// future / isolate hop): backed by four atomic-relaxed loads, cheap
/// enough to call from a UI poll loop.
///
/// Counters are process-wide and include workers spawned by every
/// concurrent caller, including those passing different
/// `dnsConcurrencyCap` values — the underlying pool is shared by
/// design (see `ARCHITECTURE.md`'s "Timeout budget and bounded DNS"
/// section). The snapshot is racy by construction: each individual
/// counter is read atomically, but a caller may see a slightly stale
/// combination across counters (e.g. `inFlight` lagging `recovered`
/// by one bump). It is never logically impossible.
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
NtsDnsPoolStats ntsDnsPoolStats() => ffi.ntsDnsPoolStats();

/// Force a fresh NTS-KE handshake against `spec` and return the number
/// of cookies the server delivered. Replaces any cached session for that
/// spec.
///
/// `timeoutMs` and `dnsConcurrencyCap` carry the same semantics as on
/// [ntsQuery] and default to [kDefaultTimeoutMs] /
/// [kDefaultDnsConcurrencyCap] when omitted.
Future<int> ntsWarmCookies({
  required NtsServerSpec spec,
  int timeoutMs = kDefaultTimeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
}) => ffi.ntsWarmCookies(
  spec: spec,
  timeoutMs: timeoutMs,
  dnsConcurrencyCap: dnsConcurrencyCap,
);
