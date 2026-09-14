// Shared getTime orchestration.
//
// Part of the nts.dart library; see that file for the imports,
// re-exports, and defaults these declarations rely on.

part of 'nts.dart';

// --- getTime orchestration --------------------------------------------
//
// Shared engine behind the top-level `ntsGetTime` and
// `NtsClient.getTime`. Both entry points bind their own `warm` /
// `query` closures (top-level functions vs. per-client methods) and
// delegate the budget accounting, burst loop, lowest-delay selection,
// and compensation here so the two surfaces cannot drift.
//
// `_kGetTimeTimeout` is one total budget: a single sleep-aware
// monotonic clock read before the handshake meters every underlying
// call (see `clock.dart`), and each call receives only the remaining
// balance; the budget keeps depleting across device suspend, so a
// mid-call sleep surfaces as `timeout(ntp)` rather than a
// stalled-then-overrun budget. The lower-level wrappers validate
// `timeout >= 1ms`, so a balance below that floor is refused here —
// surfaced as `timeout(ntp)`, never rounded up and dispatched —
// rather than tripping their `invalidSpec` range check with a
// confusing message.

// Upper bound on the number of burst `query` samples taken after the
// warming handshake. The effective burst size is
// `min(_kGetTimeMaxBurst, freshCookies)` — each query spends one
// cookie, so the burst never exhausts the pool it just filled. Eight
// samples give a tight lowest-delay selection on steady paths and
// enough spread to ride out jitter on cellular / Wi-Fi ones.
const int _kGetTimeMaxBurst = 8;

// Total budget for the whole `getTime` call, shared across the
// warming handshake and every burst query as one shrinking deadline
// metered on the sleep-aware clock above. Sized for the 8-query
// burst over a cold-radio cellular path (DNS + TCP + TLS + KE
// handshake plus eight serial UDP round-trips); on fast paths the
// call returns as soon as the burst completes, so the generous cap
// only moves the worst-case failure latency, never the happy path.
const Duration _kGetTimeTimeout = Duration(milliseconds: 8000);

// Smallest remaining balance worth dispatching on. Mirrors the
// `timeout >= 1ms` range check the lower-level wrappers enforce: a
// balance below this cannot be forwarded without either tripping that
// check (`invalidSpec`, a misleading surface for an exhausted budget)
// or being rounded up, which would extend the total budget. Both the
// warm phase and every burst iteration gate on it, so the two never
// disagree about when the budget is spent.
const Duration _kMinDispatchBudget = Duration(milliseconds: 1);

// The shape shared by the top-level `ntsWarmCookies` / `ntsQuery`
// functions and their `NtsClient` method counterparts, so `_getTimeFor`
// can select an endpoint pair by tear-off and bind the arguments once.
typedef _WarmEndpoint =
    Future<NtsWarmCookiesOutcome> Function({
      required NtsServerSpec spec,
      Duration timeout,
      int dnsConcurrencyCap,
      int bridgeConcurrencyCap,
      DateTime? verificationTime,
      StrictClockContext? context,
    });

typedef _QueryEndpoint =
    Future<NtsTimeSample> Function({
      required NtsServerSpec spec,
      Duration timeout,
      int dnsConcurrencyCap,
      int bridgeConcurrencyCap,
      DateTime? verificationTime,
      StrictClockContext? context,
    });

typedef _BoundEndpoints = ({
  Future<NtsWarmCookiesOutcome> Function(Duration timeout) warm,
  Future<NtsTimeSample> Function(Duration timeout) query,
});

// Shared preamble and closure binding for the `getTime` entry points.
// `client` selects which pair of endpoints the burst runs against: its
// own methods when non-null (per-client session table), the top-level
// functions when null (the process-wide default client). `context`,
// when non-null, is forwarded so the bridge gate meters each call's
// queue wait on the strict clock. Binding the forwarded arguments once
// here is what keeps the surfaces from drifting.
_BoundEndpoints _bindGetTimeEndpoints({
  required NtsServerSpec spec,
  required DateTime? verificationTime,
  required NtsClient? client,
  required StrictClockContext? context,
}) {
  final resolvedVerificationMs = _verificationMs(verificationTime);
  _validateGetTime(spec: spec, verificationTimeMs: resolvedVerificationMs);
  final resolved = _verificationInstant(resolvedVerificationMs);
  final _WarmEndpoint warmEndpoint = client == null
      ? ntsWarmCookies
      : client.warmCookies;
  final _QueryEndpoint queryEndpoint = client == null ? ntsQuery : client.query;
  return (
    warm: (timeout) => warmEndpoint(
      spec: spec,
      timeout: timeout,
      dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
      bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
      verificationTime: resolved,
      context: context,
    ),
    query: (timeout) => queryEndpoint(
      spec: spec,
      timeout: timeout,
      dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
      bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
      verificationTime: resolved,
      context: context,
    ),
  );
}

// `async` deliberately: both entry points promise their validation
// failures arrive as a rejected future, not as a synchronous throw,
// and `NtsClient.getTime` delegates here with an expression body.
Future<NtsSyncedTime> _getTimeFor({
  required NtsServerSpec spec,
  required DateTime? verificationTime,
  NtsClient? client,
}) async {
  final endpoints = _bindGetTimeEndpoints(
    spec: spec,
    verificationTime: verificationTime,
    client: client,
    context: null,
  );
  return _getTime(warm: endpoints.warm, query: endpoints.query);
}

// Strict counterpart of `_getTimeFor`: same validation and endpoint
// binding, with `context` metering the budget, the bridge gate, the
// receipt attribution and the returned projection.
Future<StrictSyncedTime> _getTimeStrictFor({
  required NtsServerSpec spec,
  required StrictClockContext context,
  required DateTime? verificationTime,
  NtsClient? client,
}) async {
  final endpoints = _bindGetTimeEndpoints(
    spec: spec,
    verificationTime: verificationTime,
    client: client,
    context: context,
  );
  return _getTimeStrict(
    context: context,
    warm: endpoints.warm,
    query: endpoints.query,
  );
}

Future<NtsSyncedTime> _getTime({
  required Future<NtsWarmCookiesOutcome> Function(Duration timeout) warm,
  required Future<NtsTimeSample> Function(Duration timeout) query,
}) async {
  final clock = MonotonicClock.instance;
  final startMicros = clock.nowMicros();
  // Exact `Duration` subtraction at microsecond resolution. The
  // ms-precision conversion happens once per dispatch, at the FFI
  // boundary (`_ffiTimeoutMs`), which rounds *up* so a live sub-ms
  // remainder is never rounded down to a dead budget. The trade-off:
  // each forwarded ms value may exceed the true remainder by <1 ms
  // (bounded overall to <1 ms on the final dispatch), rather than the
  // pre-Duration shape's strict floor.
  Duration remaining() => _kGetTimeTimeout - clock.elapsedSince(startMicros);

  // Warm phase: always a fresh handshake, so the burst below runs
  // against a full cookie pool and a known-fresh AEAD session. A
  // failure here is fatal by design — there is nothing to sample with.
  // The handshake draws from the shared balance too (not a fresh
  // `_kGetTimeTimeout`), so overhead accrued since `budget` started
  // is charged against the total rather than silently extending it.
  //
  // A balance already below the lower-level `timeout >= 1ms` floor is
  // refused rather than rounded up to 1ms: dispatching would extend
  // the documented total budget, and a handshake that then *succeeds*
  // would replace the cached session for `spec` (the process-wide
  // one on the default-client path) on a call that should never have
  // reached protocol work. Only a suspend landing inside the few
  // instructions between `startMicros` and here can drain the balance
  // this early, which is exactly the case the sleep-aware clock exists
  // to charge for. The phase matches the post-handshake exhaustion
  // below — `ntp` is this path's one synthetic "budget gone, no sample
  // produced" signal — and `trustBackend` is absent because no
  // handshake ran to attribute one.
  final warmBudget = remaining();
  if (warmBudget < _kMinDispatchBudget) {
    throw const NtsError.timeout(phase: TimeoutPhase.ntp);
  }
  final outcome = await warm(warmBudget);
  if (outcome.freshCookies < 1) {
    throw NtsError.noCookies(trustBackend: outcome.trustBackend);
  }

  final burst = math.min(_kGetTimeMaxBurst, outcome.freshCookies);
  NtsTimeSample? best;
  // Post-`await` monotonic instant (on the shared clock's timeline,
  // relative to `startMicros`) at which the current `best` sample's
  // reply was observed on the Dart side. Fallback input for the
  // anchor-lag arithmetic below when the sample's wire-level
  // `recvBoottimeMicros` stamp fails the epoch-plausibility window
  // (hand-built fixtures, mock-mode Stopwatch clock fallback).
  var bestArrivalMicros = 0;
  var samplesUsed = 0;
  // Per-sample offsets θ for the jitter computation (RFC 5905 §10).
  // Parallel to arrival order; the winning sample's offset is read
  // from `best` directly.
  final offsets = <int>[];
  Object? lastError;
  StackTrace? lastStack;
  for (var i = 0; i < burst; i++) {
    final left = remaining();
    if (left < _kMinDispatchBudget) break;
    try {
      final sample = await query(left);
      samplesUsed++;
      offsets.add(sample.offsetMicros);
      if (best == null ||
          _effectiveDelayMicros(sample) < _effectiveDelayMicros(best)) {
        best = sample;
        bestArrivalMicros = clock.nowMicros() - startMicros;
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
  // the network delay (peer delay δ when plausible, else the measured
  // round trip — see `_effectiveDelayMicros`) estimates the server
  // clock at the moment the reply arrived. That estimate is only
  // valid at the winning recv instant, while `NtsSyncedTime` captures
  // its monotonic anchor at construction — which happens after the
  // whole burst has run. Bridge the gap by advancing the compensated
  // UTC across the time elapsed since the winning reply arrived
  // (`anchorLagMicros`), so the value handed to the constructor is
  // valid "now" even when the lowest-delay sample was not the last
  // query in the burst.
  //
  // Preferred lag source: the sample's wire-level receipt stamp
  // (`recvBoottimeMicros`), taken inside the native worker immediately
  // after the UDP recv. It shares the `MonotonicClock` timeline by
  // construction, and unlike the post-`await` stamp it excludes the
  // FFI-return / worker-handoff / event-loop scheduling latency δ —
  // the previous arithmetic under-advanced the compensated UTC by
  // exactly δ. Plausibility window: on the production path the stamp
  // must fall between the burst start and the post-`await` observation
  // (recv happens after dispatch and before the `await` returns). A
  // stamp outside that window means an epoch mismatch (hand-built
  // fixture, mock clock on the Stopwatch fallback), in which case fall
  // back to the post-`await` approximation rather than injecting an
  // arbitrary cross-epoch delta.
  final nowMicros = clock.nowMicros();
  final postAwaitLagMicros = (nowMicros - startMicros) - bestArrivalMicros;
  final wireLagMicros = nowMicros - best.recvBoottimeMicros;
  final anchorLagMicros =
      (best.recvBoottimeMicros >= startMicros &&
          wireLagMicros >= postAwaitLagMicros)
      ? wireLagMicros
      : postAwaitLagMicros;
  final stats = _burstStatistics(best, offsets);
  return NtsSyncedTime(
    utcUnixMicros:
        best.utcUnixMicros + stats.delayMicros ~/ 2 + anchorLagMicros,
    roundTripMicros: best.roundTripMicros,
    samplesUsed: samplesUsed,
    trustBackend: best.trustBackend,
    offsetMicros: best.offsetMicros,
    jitterMicros: stats.jitterMicros,
    errorBoundMicros: stats.errorBoundMicros,
  );
}

// Strict variant of `_getTime`. Same burst, selection and compensation,
// with every clock decision made on `context` and no fallback at any
// of them:
//
// - The budget is metered on `context`. A read that faults fails the
//   call as `clockFault(awaitResult)`; a spent budget is still
//   `timeout(ntp)`. No fresh budget is ever started after a fault.
// - Every `await` is followed by a strict read before its result is
//   used, so a bridge reset or native generation change that lands
//   while the call was parked fails the call rather than letting a
//   stale completion through.
// - A sample is attributed to `context` by its receipt stamp's
//   generation and backend (`attributeStrictReceipt`), never by the
//   plausibility window the legacy path uses. A missing or foreign
//   stamp fails the call as `clockFault(attribution)` — not tolerated
//   as a burst failure, because a later successful read could not
//   certify the sample after the fact.
// - The anchor lag is the strict receipt aged on `context`; a stamp
//   that does not order against the context's own readings is a
//   regression and fails the call.
Future<StrictSyncedTime> _getTimeStrict({
  required StrictClockContext context,
  required Future<NtsWarmCookiesOutcome> Function(Duration timeout) warm,
  required Future<NtsTimeSample> Function(Duration timeout) query,
}) async {
  TrustBackend? backend;
  StrictReading read(ClockFaultStage stage) =>
      _strictRead(context, stage, trustBackend: backend);
  final start = read(ClockFaultStage.admission);
  // `now()` enforces monotonicity against `start` on this context, so
  // the difference is never negative and never clamped.
  Duration remaining() =>
      _kGetTimeTimeout -
      Duration(
        microseconds: read(ClockFaultStage.awaitResult).micros - start.micros,
      );

  final warmBudget = remaining();
  if (warmBudget < _kMinDispatchBudget) {
    throw const NtsError.timeout(phase: TimeoutPhase.ntp);
  }
  final outcome = await warm(warmBudget);
  read(ClockFaultStage.awaitResult);
  backend = outcome.trustBackend;
  if (outcome.freshCookies < 1) {
    throw NtsError.noCookies(trustBackend: backend);
  }

  final burst = math.min(_kGetTimeMaxBurst, outcome.freshCookies);
  NtsTimeSample? best;
  StrictReading? bestReceipt;
  var samplesUsed = 0;
  final offsets = <int>[];
  Object? lastError;
  StackTrace? lastStack;
  for (var i = 0; i < burst; i++) {
    final left = remaining();
    if (left < _kMinDispatchBudget) break;
    final NtsTimeSample sample;
    try {
      sample = await query(left);
    } on NtsError catch (err, stack) {
      // Same best-effort posture as the legacy burst. A `clockFault`
      // from the query lands here too: if it moved the generation the
      // next strict read above fails the call, and a per-sample
      // `suspendedInFlight` verdict is exactly what a retry is for.
      lastError = err;
      lastStack = stack;
      continue;
    }
    final receipt = _attributeReceipt(
      context,
      sample,
      notBefore: start,
      trustBackend: backend,
    );
    // Post-`await` re-validation and the cross-reader ordering check
    // in one read: `elapsedSince` fails on a bridge reset, a native
    // generation change, or a stamp above the context's fresh reading.
    _strictElapsed(
      context,
      receipt,
      ClockFaultStage.attribution,
      trustBackend: backend,
    );
    samplesUsed++;
    offsets.add(sample.offsetMicros);
    if (best == null ||
        _effectiveDelayMicros(sample) < _effectiveDelayMicros(best)) {
      best = sample;
      bestReceipt = receipt;
    }
  }

  if (best == null) {
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack!);
    }
    throw NtsError.timeout(phase: TimeoutPhase.ntp, trustBackend: backend);
  }

  // The anchor is a fresh reading on `context`; the receipt was
  // already ordered below an earlier reading on the same context, and
  // `now()` is monotonic against that, so the lag is non-negative.
  final anchor = read(ClockFaultStage.projection);
  final anchorLagMicros = anchor.micros - bestReceipt!.micros;
  final stats = _burstStatistics(best, offsets);
  return StrictSyncedTime(
    context: context,
    anchor: anchor,
    utcUnixMicros:
        best.utcUnixMicros + stats.delayMicros ~/ 2 + anchorLagMicros,
    referenceMicros: bestReceipt.micros,
    roundTripMicros: best.roundTripMicros,
    samplesUsed: samplesUsed,
    trustBackend: best.trustBackend,
    offsetMicros: best.offsetMicros,
    jitterMicros: stats.jitterMicros,
    errorBoundMicros: stats.errorBoundMicros,
  );
}

// The RFC 5905 statistics both `getTime` variants attach to the
// returned time: the delay used for compensation, the burst jitter ψ,
// and the root-distance error bound.
//
// Jitter (§10) is the RMS of the offset differences between the
// winning sample and every other burst sample; with a single sample
// the sum is empty and ψ is 0. The error bound at the anchor instant
// is half the winning sample's network delay + half the server's root
// delay + the server's root dispersion + ψ. Fixture-shaped samples
// (all-zero 7.1 fields) degrade to the pre-7.1 `roundTrip / 2` bound.
({int delayMicros, int jitterMicros, int errorBoundMicros}) _burstStatistics(
  NtsTimeSample best,
  List<int> offsets,
) {
  final theta0 = best.offsetMicros;
  var sumSq = 0.0;
  for (final theta in offsets) {
    final d = (theta - theta0).toDouble();
    sumSq += d * d;
  }
  final jitterMicros = offsets.length > 1
      ? math.sqrt(sumSq / (offsets.length - 1)).round()
      : 0;
  final delayMicros = _effectiveDelayMicros(best);
  final errorBoundMicros =
      delayMicros ~/ 2 +
      best.rootDelayMicros ~/ 2 +
      best.rootDispersionMicros +
      jitterMicros;
  return (
    delayMicros: delayMicros,
    jitterMicros: jitterMicros,
    errorBoundMicros: errorBoundMicros,
  );
}

// --- strict clock helpers ---------------------------------------------
//
// Every strict read the wrapper makes on a caller's context goes
// through these, so a `StrictClockError` always reaches the caller as
// `NtsError.clockFault` carrying the stage that read served, the
// context's generation, and the trust backend resolved so far. The
// original stack is preserved so the trace points at the read, not at
// the conversion.

NtsError _clockFaultError(
  StrictClockContext context,
  ClockFaultStage stage,
  StrictClockError fault, {
  TrustBackend? trustBackend,
}) => NtsError.clockFault(
  stage: stage,
  fault: fault,
  generation: context.generation,
  trustBackend: trustBackend,
);

StrictReading _strictRead(
  StrictClockContext context,
  ClockFaultStage stage, {
  TrustBackend? trustBackend,
}) {
  try {
    return context.now();
  } on StrictClockError catch (fault, stack) {
    Error.throwWithStackTrace(
      _clockFaultError(context, stage, fault, trustBackend: trustBackend),
      stack,
    );
  }
}

Duration _strictElapsed(
  StrictClockContext context,
  StrictReading earlier,
  ClockFaultStage stage, {
  TrustBackend? trustBackend,
}) {
  try {
    return context.elapsedSince(earlier);
  } on StrictClockError catch (fault, stack) {
    Error.throwWithStackTrace(
      _clockFaultError(context, stage, fault, trustBackend: trustBackend),
      stack,
    );
  }
}

StrictReading _attributeReceipt(
  StrictClockContext context,
  NtsTimeSample sample, {
  required StrictReading notBefore,
  TrustBackend? trustBackend,
}) {
  try {
    return attributeStrictReceipt(context, sample, notBefore: notBefore);
  } on StrictClockError catch (fault, stack) {
    Error.throwWithStackTrace(
      _clockFaultError(
        context,
        ClockFaultStage.attribution,
        fault,
        trustBackend: trustBackend,
      ),
      stack,
    );
  }
}

// The network delay used for burst selection, one-way compensation,
// and the error bound: the RFC 5905 peer delay δ when it falls in
// `(0, roundTripMicros]` (δ excludes server processing time), else
// the locally measured round trip.
//
// Only the lower bound is diagnostic. A `0` marks a pre-7.1 fixture,
// and a non-positive δ is evidence of an implausible timestamp
// exchange — a local clock step mid-exchange, a server clock stepped
// between T2 and T3, or server stamps that are simply inconsistent.
//
// The upper bound is a selection policy, not a clock-integrity test.
// It admits δ on healthy samples under ordinary scheduling: T1 shares
// an anchor with `roundTripMicros` (stamped immediately before the
// request is built and sealed, which the send follows), so the only
// work δ carries that the round trip does not is that request build
// and seal plus the socket write-timeout re-arm that bounds the send
// against the call's remaining budget — neither of which blocks on
// I/O. A δ above `roundTripMicros` by more than that overhead is a
// forward clock step, a slew separating the wall-clock T1/T4 pair
// from the monotonic round trip, or — on a loaded host — preemption
// of the worker between T1 and the send. Taking the fallback is
// therefore not evidence of clock corruption. It is also not a
// wasted rejection: an interval `p` between T1 and the send lands
// inside T2−T1 with nothing offsetting it in T3−T4, adding `p` to δ
// and `p/2` to `offsetMicros`, so the fallback is what keeps `p` out
// of the delay the compensation below halves. It cannot repair the
// `p/2` already in θ — this window selects a delay, it does not
// screen θ. Before 9.2 T1 was stamped ahead of the bind, so δ ran
// 1–9% above the round trip and this window selected the fallback on
// every healthy sample.
int _effectiveDelayMicros(NtsTimeSample s) =>
    (s.peerDelayMicros > 0 && s.peerDelayMicros <= s.roundTripMicros)
    ? s.peerDelayMicros
    : s.roundTripMicros;
