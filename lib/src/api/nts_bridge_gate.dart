// Isolate-local bridge admission gate.
//
// Part of the nts.dart library; see that file for the imports,
// re-exports, and defaults these declarations rely on.

part of 'nts.dart';

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
// semantics as the Rust-side DNS resolver pool. `_sweepBridgeQueue`
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
//
// Deadlines are held as absolute `MonotonicClock` readings and swept
// by a single queue-wide timer rather than one full-length `Timer`
// per waiter. `Timer` runs on the event loop's suspend-frozen clock,
// so a device that sleeps while a waiter is queued resumes with the
// timer still owing its whole remaining slice even though the
// sleep-aware budget is long gone — the waiter would keep parking for
// an outcome already decided. The sweeper caps each arming at
// `_kBridgeSweepSliceCap`, so a resume re-evaluates against the
// boottime clock within one slice; the cap never delays a deadline
// that is nearer than the cap, which is every deadline while awake.

class _BridgeWaiter {
  final int cap;

  /// Absolute [MonotonicClock] reading at which this waiter's budget
  /// runs out. Sleep-aware, unlike the event loop's timer clock.
  final int deadlineMicros;

  /// Captured at enqueue time so the timeout error's stack trace
  /// points at the wrapper call path that queued the waiter, not at
  /// the sweep callback that fired the deadline.
  final StackTrace enqueueTrace;

  final Completer<void> admitted = Completer<void>();
  _BridgeWaiter(this.cap, this.deadlineMicros, this.enqueueTrace);
}

/// Upper bound on how long the queue sweeper parks between deadline
/// re-evaluations, and therefore on how late a still-queued waiter
/// can be unparked after the device resumes from deep sleep. Only
/// armed while the queue is non-empty, so an idle process schedules
/// nothing.
const Duration _kBridgeSweepSliceCap = Duration(milliseconds: 250);

int _bridgeInFlight = 0;
final List<_BridgeWaiter> _bridgeQueue = <_BridgeWaiter>[];
Timer? _bridgeSweep;

/// Absolute boot-clock reading [_bridgeSweep] is due to fire at. Only
/// meaningful while [_bridgeSweep] is non-null, which holds exactly
/// while [_bridgeQueue] is non-empty. Lets an arrival decide whether
/// the pending sweep already covers it without scanning the queue.
int _bridgeSweepAtMicros = 0;

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
    final queueClock = MonotonicClock.instance;
    final queueStartMicros = queueClock.nowMicros();
    final waiter = _BridgeWaiter(
      bridgeConcurrencyCap,
      queueStartMicros + timeout.inMicroseconds,
      StackTrace.current,
    );
    final wasEmpty = _bridgeQueue.isEmpty;
    _bridgeQueue.add(waiter);
    if (wasEmpty || waiter.deadlineMicros < _bridgeSweepAtMicros) {
      // Re-arm only when this arrival is not already covered. The
      // guard is against the pending sweep's fire time, not against
      // the queue minimum: under the slice cap a sweep is usually due
      // long before the nearest deadline, so a new nearest that still
      // falls after it needs nothing. A non-empty queue always has a
      // pending sweep, so the else branch is safe to leave silent.
      _armBridgeSweep(queueStartMicros, waiter.deadlineMicros);
    }
    // `_sweepBridgeQueue` increments `_bridgeInFlight` on this call's
    // behalf before completing the future, so both branches converge
    // holding exactly one slot. No per-waiter cancellation is needed
    // on either exit: an admitted or expired entry is dropped by the
    // next compaction pass.
    await waiter.admitted.future;
    remainingTimeout = timeout - queueClock.elapsedSince(queueStartMicros);
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
    _sweepBridgeQueue();
  }
}

/// Park until [nearestMicros], capped at [_kBridgeSweepSliceCap].
///
/// The cap is what makes cancellation sleep-aware without polling: a
/// resume from deep sleep is followed by a sweep within one slice,
/// which re-reads [MonotonicClock] and expires everything the sleep
/// consumed. While awake the nearest deadline is almost always inside
/// the cap, so the extra wake-ups only occur under a queue whose
/// waiters all have long budgets.
///
/// [nearestMicros] is supplied by the caller rather than derived here:
/// both call sites already know it — the sweep from its compaction
/// pass, an arrival from its own deadline having beaten the pending
/// fire time — so deriving it would re-walk a queue that was just
/// walked, or walk one for a single new entry.
void _armBridgeSweep(int nowMicros, int nearestMicros) {
  _bridgeSweep?.cancel();
  if (_bridgeQueue.isEmpty) {
    _bridgeSweep = null;
    return;
  }
  // Clamped rather than used raw: a deadline already behind `nowMicros`
  // must fire on the next turn, not be handed to `Timer` as a negative
  // duration, and one further out than the cap must still wake within a
  // slice so a resume from suspend is not waited out.
  final sliceMicros = (nearestMicros - nowMicros).clamp(
    0,
    _kBridgeSweepSliceCap.inMicroseconds,
  );
  _bridgeSweepAtMicros = nowMicros + sliceMicros;
  _bridgeSweep = Timer(Duration(microseconds: sliceMicros), _sweepBridgeQueue);
}

void _sweepBridgeQueue() {
  // Single-pass in-place compaction keeps the sweep O(n): expired and
  // admitted waiters are dropped, retained waiters shift down, and the
  // tail is truncated once — versus the O(n²) element shifting a
  // per-waiter `removeAt` would cost under a large queued burst.
  // Mutating in place is safe: `complete()` / `completeError()` only
  // schedule microtasks and the loop has no suspension points, so no
  // timer or waiter continuation can observe the queue mid-sweep.
  //
  // One clock reading serves both the whole pass and the re-arm, so a
  // burst of waiters sharing a deadline expires together rather than
  // splitting across readings taken microseconds apart. The empty
  // queue exits before the read: every uncontended call runs this on
  // release, and that path should not pay for an FFI clock hop.
  if (_bridgeQueue.isEmpty) return;
  final nowMicros = MonotonicClock.instance.nowMicros();
  var kept = 0;
  // Tracked alongside the compaction rather than rescanned afterwards:
  // the retained branch below visits exactly the surviving set, so the
  // re-arm's input costs nothing extra.
  var nearestMicros = 0;
  for (var i = 0; i < _bridgeQueue.length; i++) {
    final waiter = _bridgeQueue[i];
    if (waiter.admitted.isCompleted) {
      // Already resolved by an earlier pass in this same turn. Drop.
      continue;
    }
    if (waiter.deadlineMicros <= nowMicros) {
      // Budget spent while queued. Expiring here rather than admitting
      // keeps the freed slot for a waiter that can still use it; the
      // dispatch-side residual check would only have rejected this one
      // again.
      waiter.admitted.completeError(
        const NtsError.timeout(phase: TimeoutPhase.bridgeSaturation),
        waiter.enqueueTrace,
      );
      continue;
    }
    if (_bridgeInFlight < waiter.cap) {
      _bridgeInFlight++;
      waiter.admitted.complete();
    } else {
      if (kept == 0 || waiter.deadlineMicros < nearestMicros) {
        nearestMicros = waiter.deadlineMicros;
      }
      _bridgeQueue[kept++] = waiter;
    }
  }
  _bridgeQueue.length = kept;
  _armBridgeSweep(nowMicros, nearestMicros);
}
