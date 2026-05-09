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

import '../ffi/api/nts.dart' as ffi;
import 'errors.dart';
import 'models.dart';

export 'errors.dart';
export 'models.dart';

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
///
/// Throws an [NtsError] on every failure path.
Future<NtsTimeSample> ntsQuery({
  required NtsServerSpec spec,
  int timeoutMs = kDefaultTimeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
}) async {
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
/// The returned [NtsWarmCookiesOutcome.phaseTimings] only covers the KE
/// pipeline (DNS, connect, TLS, KE record I/O); there is no UDP NTP
/// exchange on this path, so the `Ntp` phase is implicitly zero.
///
/// Throws an [NtsError] on every failure path.
Future<NtsWarmCookiesOutcome> ntsWarmCookies({
  required NtsServerSpec spec,
  int timeoutMs = kDefaultTimeoutMs,
  int dnsConcurrencyCap = kDefaultDnsConcurrencyCap,
}) async {
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
);

NtsWarmCookiesOutcome _publicWarm(ffi.NtsWarmCookiesOutcome o) =>
    NtsWarmCookiesOutcome(
      freshCookies: o.freshCookies,
      phaseTimings: _publicPhase(o.phaseTimings),
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
  ffi.NtsError_InvalidSpec(:final field0) => NtsError.invalidSpec(field0),
  ffi.NtsError_Network(:final field0) => NtsError.network(field0),
  ffi.NtsError_KeProtocol(:final field0) => NtsError.keProtocol(field0),
  ffi.NtsError_NtpProtocol(:final field0) => NtsError.ntpProtocol(field0),
  ffi.NtsError_Authentication(:final field0) => NtsError.authentication(field0),
  ffi.NtsError_Timeout(:final field0) => NtsError.timeout(
    _publicTimeoutPhase(field0),
  ),
  ffi.NtsError_NoCookies() => const NtsError.noCookies(),
  ffi.NtsError_Internal(:final field0) => NtsError.internal(field0),
};
