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
    });

typedef _QueryEndpoint =
    Future<NtsTimeSample> Function({
      required NtsServerSpec spec,
      Duration timeout,
      int dnsConcurrencyCap,
      int bridgeConcurrencyCap,
      DateTime? verificationTime,
    });

// Shared preamble and closure binding for the two `getTime` entry
// points. `client` selects which pair of endpoints the burst runs
// against: its own methods when non-null (per-client session table),
// the top-level functions when null (the process-wide default client).
// Binding the forwarded arguments once here is what keeps the two
// surfaces from drifting.
//
// `async` deliberately: both entry points promise their validation
// failures arrive as a rejected future, not as a synchronous throw,
// and `NtsClient.getTime` delegates here with an expression body.
Future<NtsSyncedTime> _getTimeFor({
  required NtsServerSpec spec,
  required DateTime? verificationTime,
  NtsClient? client,
}) async {
  final resolvedVerificationMs = _verificationMs(verificationTime);
  _validateGetTime(spec: spec, verificationTimeMs: resolvedVerificationMs);
  final resolved = _verificationInstant(resolvedVerificationMs);
  final _WarmEndpoint warmEndpoint = client == null
      ? ntsWarmCookies
      : client.warmCookies;
  final _QueryEndpoint queryEndpoint = client == null ? ntsQuery : client.query;
  return _getTime(
    warm: (timeout) => warmEndpoint(
      spec: spec,
      timeout: timeout,
      dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
      bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
      verificationTime: resolved,
    ),
    query: (timeout) => queryEndpoint(
      spec: spec,
      timeout: timeout,
      dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
      bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
      verificationTime: resolved,
    ),
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
  // Sample jitter ψ (RFC 5905 §10): RMS of the offset differences
  // between the winning sample and every other burst sample. With a
  // single sample the sum is empty and ψ is 0.
  final theta0 = best.offsetMicros;
  var sumSq = 0.0;
  for (final theta in offsets) {
    final d = (theta - theta0).toDouble();
    sumSq += d * d;
  }
  final jitterMicros = offsets.length > 1
      ? math.sqrt(sumSq / (offsets.length - 1)).round()
      : 0;
  // Worst-case error bound at the anchor instant, following the
  // RFC 5905 root-distance recipe: half the winning sample's network
  // delay + half the server's root delay + the server's root
  // dispersion + sample jitter. Fixture-shaped samples (all-zero 7.1
  // fields) degrade to the pre-7.1 `roundTrip / 2` bound.
  final delayMicros = _effectiveDelayMicros(best);
  final errorBoundMicros =
      delayMicros ~/ 2 +
      best.rootDelayMicros ~/ 2 +
      best.rootDispersionMicros +
      jitterMicros;
  return NtsSyncedTime(
    utcUnixMicros: best.utcUnixMicros + delayMicros ~/ 2 + anchorLagMicros,
    roundTripMicros: best.roundTripMicros,
    samplesUsed: samplesUsed,
    trustBackend: best.trustBackend,
    offsetMicros: best.offsetMicros,
    jitterMicros: jitterMicros,
    errorBoundMicros: errorBoundMicros,
  );
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
// I/O. A δ above `roundTripMicros` by more than that fixed overhead
// is a forward clock step, a slew separating the wall-clock T1/T4
// pair from the monotonic round trip, or — on a loaded host —
// preemption of the worker between T1 and the send, which inflates δ
// while leaving θ intact. Taking the fallback is therefore not
// evidence of clock corruption: it is the quantity actually measured
// across the exchange, so it costs accuracy rather than correctness
// whichever of those put δ out of range. Before 9.2 T1 was stamped
// ahead of the bind, so δ ran 1–9% above the round trip and this
// window selected the fallback on every healthy sample.
int _effectiveDelayMicros(NtsTimeSample s) =>
    (s.peerDelayMicros > 0 && s.peerDelayMicros <= s.roundTripMicros)
    ? s.peerDelayMicros
    : s.roundTripMicros;
