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
    final queueClock = MonotonicClock.instance;
    final queueStartMicros = queueClock.nowMicros();
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
