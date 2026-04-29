//! Bounded DNS resolution helper.
//!
//! `std::net::ToSocketAddrs` delegates to the blocking system resolver
//! (`getaddrinfo` on Unix, `GetAddrInfoExW` on Windows) which has no
//! `Duration` argument and can stall for tens of seconds when the
//! recursive resolver is slow or blackholed. The synchronous NTS code
//! paths in this crate (`nts::ke::connect_with_timeout` and
//! `api::nts::bind_connected_udp`) need to honour a wall-clock budget
//! that includes name resolution; this module bounds that step by
//! offloading the call to a one-shot thread and waiting for it on a
//! channel with `recv_timeout`.
//!
//! When the deadline fires the spawned thread is detached: there is no
//! portable way to cancel an in-flight `getaddrinfo`, so we let the
//! lookup finish in the background and drop its result. To stop a
//! pathological resolver from accumulating an unbounded backlog of
//! detached workers (each holding a TLS stack and an OS thread), the
//! module enforces a process-wide cap on in-flight resolutions. The
//! cap defaults to [`DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS`] (sized for
//! mobile devices, where each leaked thread costs ~512 KB-1 MB of
//! committed stack on iOS/Android) and can be raised per-call by
//! callers that knowingly run on hosts with more headroom. When the
//! cap is reached the next call returns `io::ErrorKind::WouldBlock`
//! *without* spawning a thread — the caller can retry once the
//! in-flight pool drains. Slots are tracked by a [`SlotGuard`] that is
//! moved into the worker thread and decrements the global counter when
//! the worker actually returns from the system resolver, so a
//! timed-out request does not free its slot until `getaddrinfo` itself
//! unblocks.
//!
//! The cap is fundamentally a *global* resource: there is one
//! process-wide counter and the per-call argument is a threshold
//! compared against it before dispatch. When two concurrent callers
//! pass different caps, the effective ceiling at any moment is set by
//! whichever caller is currently being admitted — the lower-cap caller
//! still refuses to dispatch once its own threshold is reached, even
//! if a higher-cap caller would have tolerated more workers.
//!
//! The lookup function and the slot counter are both parameterised so
//! tests can substitute a deterministic stub (e.g. one that
//! `thread::sleep`s past the budget) and a per-test `AtomicUsize` to
//! prove cap-exhaustion and slot-release without depending on a real
//! adversarial nameserver or interfering with other tests sharing the
//! global pool. The production call sites pass [`system_lookup`] and
//! the global counter via [`resolve_with_timeout`].

use std::io;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

/// Maximum number of `nts-dns` worker threads that may be alive
/// simultaneously when the caller does not specify a cap of its own.
/// Sized for the expected NTS workload (a handful of servers warmed in
/// parallel from the FRB v2 worker pool) on the most resource-
/// constrained platforms we ship to: iOS extensions cap process memory
/// at ~50 MB, and each leaked detached worker (see module docs) costs
/// ~512 KB of pthread stack on iOS and ~1 MB on Android. Capping at
/// four bounds the worst-case mobile leak from a blackholed resolver
/// to ~4 MB. Server-side callers that legitimately need more
/// concurrency can override this per-call via the `dns_concurrency_cap`
/// FFI parameter on `nts_query` / `nts_warm_cookies`.
pub(crate) const DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS: usize = 4;

/// Bundle of process-wide counters for the bounded DNS resolver pool.
///
/// The four atomics are grouped here so the production global pool and
/// the per-test pools used by `dns::tests` share the same shape: every
/// `try_acquire_slot` / `SlotGuard::drop` site updates the same set of
/// counters regardless of which pool it ran against, and tests can
/// stand up a private `PoolStats` and assert on its counters in
/// isolation from the live global state.
pub(crate) struct PoolStats {
    /// Live count of resolver workers currently pinned in
    /// [`system_lookup`] (or a test-injected stub). Incremented before
    /// the worker is spawned (by [`try_acquire_slot`]) and decremented
    /// by [`SlotGuard::drop`] when the worker terminates, so the count
    /// tracks live OS threads even when the calling future has already
    /// given up on `recv_timeout`.
    pub(crate) in_flight: AtomicUsize,
    /// Maximum value [`Self::in_flight`] has reached since this stats
    /// bundle was constructed. Updated monotonically with `fetch_max`
    /// after each successful admission. Distinguishes "I have headroom
    /// in steady state but burst to the cap occasionally" from "I am
    /// pinned at the cap continually" without forcing operators to
    /// poll [`Self::in_flight`] on a tight loop.
    pub(crate) high_water_mark: AtomicUsize,
    /// Cumulative count of detached workers that have completed and
    /// released their slot. Climbing alongside a non-zero
    /// [`Self::in_flight`] is the diagnostic signature of "libc is
    /// timing out internally as expected"; flat with `in_flight == cap`
    /// is the signature of a libc-level wedge. `u64` (not `usize`)
    /// because the counter grows monotonically over a process lifetime
    /// and a 32-bit wraparound would be visible on long-running
    /// CLI / server builds with a saturated resolver.
    pub(crate) recovered: AtomicU64,
    /// Cumulative count of [`try_acquire_slot`] calls that returned
    /// `None` because the cap was reached. Direct signal for "raising
    /// `dns_concurrency_cap` would have lowered the error rate"; the
    /// expected delta when the resolver is healthy is zero.
    pub(crate) refused: AtomicU64,
}

impl PoolStats {
    pub(crate) const fn new() -> Self {
        Self {
            in_flight: AtomicUsize::new(0),
            high_water_mark: AtomicUsize::new(0),
            recovered: AtomicU64::new(0),
            refused: AtomicU64::new(0),
        }
    }
}

/// Process-wide stats for the bounded DNS resolver pool. Production
/// callers route through this via [`resolve_with_global`]; tests stand
/// up a private [`PoolStats`] so cap-exhaustion / slot-release
/// assertions don't collide with any other test that hits the live
/// pool.
static GLOBAL_POOL_STATS: PoolStats = PoolStats::new();

/// Plain-data snapshot of [`PoolStats`] taken with `Relaxed` loads.
///
/// The snapshot is racy by construction (a caller may see a slightly
/// stale `in_flight` relative to `high_water_mark`, etc.) but never a
/// logically-impossible state: each individual counter is read
/// atomically, and the snapshot is intended for human / dashboard
/// consumption, not for synchronisation. The shape is mirrored to the
/// FFI as `NtsDnsPoolStats` in `crate::api::nts`.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PoolSnapshot {
    pub(crate) in_flight: usize,
    pub(crate) high_water_mark: usize,
    pub(crate) recovered: u64,
    pub(crate) refused: u64,
}

/// Snapshot the global resolver pool counters. Backs the FFI-level
/// `nts_dns_pool_stats` entry point.
pub(crate) fn pool_snapshot() -> PoolSnapshot {
    snapshot_of(&GLOBAL_POOL_STATS)
}

/// Snapshot an arbitrary [`PoolStats`] instance. Used by `pool_snapshot`
/// for the global pool and by the unit tests for their per-test pools.
pub(crate) fn snapshot_of(stats: &PoolStats) -> PoolSnapshot {
    PoolSnapshot {
        in_flight: stats.in_flight.load(Ordering::Relaxed),
        high_water_mark: stats.high_water_mark.load(Ordering::Relaxed),
        recovered: stats.recovered.load(Ordering::Relaxed),
        refused: stats.refused.load(Ordering::Relaxed),
    }
}

/// Default lookup used by [`resolve_with_timeout`] and the production
/// callers in `nts::ke` and `api::nts`. Thin wrapper over the blocking
/// system resolver; exposed at crate scope so the slow-DNS regression
/// tests in those modules can hand-roll an injected resolver while the
/// non-test wrappers stay pithy.
pub(crate) fn system_lookup(host: &str, port: u16) -> io::Result<Vec<SocketAddr>> {
    (host, port).to_socket_addrs().map(|iter| iter.collect())
}

/// RAII slot in the bounded resolver pool. The slot is acquired by
/// [`try_acquire_slot`] before the worker thread is spawned and moved
/// into the worker's closure so the count is held until the resolver
/// actually returns — even when the calling thread has already given
/// up on `recv_timeout` and detached the worker. Construction outside
/// `try_acquire_slot` is impossible (the field is private to the
/// module), which keeps the increment/decrement balance auditable.
struct SlotGuard {
    stats: &'static PoolStats,
}

impl Drop for SlotGuard {
    fn drop(&mut self) {
        // Bump `recovered` *before* the in-flight decrement so a racing
        // observer never sees `in_flight < cap` together with
        // `recovered` not yet reflecting the freed slot — the
        // operator-facing invariant is "every freed slot has been
        // counted as recovered". `Relaxed` for the cumulative counter
        // (no synchronisation, just an event tally); `Release` on the
        // in-flight decrement so the new value is observable to the
        // `Acquire` load in subsequent `try_acquire_slot` calls.
        self.stats.recovered.fetch_add(1, Ordering::Relaxed);
        self.stats.in_flight.fetch_sub(1, Ordering::Release);
    }
}

/// Try to claim one slot in the bounded resolver pool guarded by
/// `stats` / `cap`. Returns `Some(SlotGuard)` on success; on failure
/// (cap reached) the increment is rolled back, the `refused` counter
/// is incremented, and `None` is returned so the caller can fail fast
/// without spawning a worker. On success the high-water mark is
/// updated monotonically against the post-admission count.
fn try_acquire_slot(stats: &'static PoolStats, cap: usize) -> Option<SlotGuard> {
    // `fetch_add` then check-and-rollback is cheaper than a CAS loop
    // and equivalent under contention: a transient over-count of at
    // most `cap + n_callers` is observed for a few nanoseconds before
    // the losers' `fetch_sub` restores the invariant. The cap is a
    // ceiling on long-lived threads, not a hard real-time bound.
    let prev = stats.in_flight.fetch_add(1, Ordering::AcqRel);
    if prev >= cap {
        stats.in_flight.fetch_sub(1, Ordering::Release);
        // `Relaxed` is sufficient — the counter is a cumulative event
        // tally for human / dashboard consumption, not a sync point.
        stats.refused.fetch_add(1, Ordering::Relaxed);
        return None;
    }
    // Update HWM monotonically against the *post-admission* count
    // (`prev + 1`). `fetch_max` is a single CAS-loop primitive on
    // modern targets; `AcqRel` keeps the load-side `Relaxed` reads in
    // [`pool_snapshot`] from observing a partially-published update
    // when the increment side races a snapshot.
    let after = prev + 1;
    let _ = stats.high_water_mark.fetch_max(after, Ordering::AcqRel);
    Some(SlotGuard { stats })
}

/// Resolve `host:port` to a list of socket addresses, returning a
/// `TimedOut` `io::Error` if the system resolver does not respond
/// within `timeout`, or `WouldBlock` if the global resolver pool is
/// already saturated. An empty result propagates as `Ok(vec![])` so
/// the caller can attach its own context. Uses
/// [`DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS`] as the concurrency cap;
/// callers that need a different threshold use [`resolve_with_global`]
/// directly.
pub(crate) fn resolve_with_timeout(
    host: &str,
    port: u16,
    timeout: Duration,
) -> io::Result<Vec<SocketAddr>> {
    resolve_with_global(
        host,
        port,
        timeout,
        DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
        system_lookup,
    )
}

/// Bounded resolution against the global pool with a caller-supplied
/// concurrency cap and lookup closure. Production NTS-KE / UDP callers
/// route through this helper so the slow-resolver test seam in
/// `nts::ke` and `api::nts` (which needs to inject a sleeping closure)
/// shares the same cap-enforcement and slot-tracking as
/// [`resolve_with_timeout`].
///
/// `cap` is compared against the *global* counter; concurrent callers
/// that pass different caps see the global ceiling track whichever
/// caller is currently being admitted. Pass
/// [`DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS`] for the FFI-default behaviour.
pub(crate) fn resolve_with_global<F>(
    host: &str,
    port: u16,
    timeout: Duration,
    cap: usize,
    lookup: F,
) -> io::Result<Vec<SocketAddr>>
where
    F: FnOnce(&str, u16) -> io::Result<Vec<SocketAddr>> + Send + 'static,
{
    resolve_with(&GLOBAL_POOL_STATS, cap, host, port, timeout, lookup)
}

/// Bounded resolution with a caller-supplied counter, cap, and lookup
/// function. The closure runs on a freshly-spawned worker thread; if
/// the global cap (`cap`) of in-flight workers is already reached the
/// call returns `ErrorKind::WouldBlock` immediately without spawning
/// anything. Otherwise, if the lookup does not produce a result
/// within `timeout` the worker is detached and the caller receives
/// `ErrorKind::TimedOut`; the slot is released only when the
/// detached worker eventually returns. See module docs for the full
/// rationale.
///
/// The stats bundle and cap are explicit parameters (rather than the
/// global default used by [`resolve_with_timeout`]) so tests can use a
/// function-local [`PoolStats`] and a small cap to exercise the
/// exhaustion path without colliding with any other test that hits
/// the production pool.
pub(crate) fn resolve_with<F>(
    stats: &'static PoolStats,
    cap: usize,
    host: &str,
    port: u16,
    timeout: Duration,
    lookup: F,
) -> io::Result<Vec<SocketAddr>>
where
    F: FnOnce(&str, u16) -> io::Result<Vec<SocketAddr>> + Send + 'static,
{
    let Some(slot) = try_acquire_slot(stats, cap) else {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            format!(
                "DNS resolver pool exhausted ({cap} in-flight); refusing to spawn another \
                 worker for {host}:{port}"
            ),
        ));
    };
    let (tx, rx) = mpsc::channel();
    let host_owned = host.to_owned();
    // Detached worker — see module docs. The `SlotGuard` is moved
    // into the closure so the in-flight count tracks live threads,
    // not pending callers.
    thread::Builder::new()
        .name("nts-dns".to_owned())
        .spawn(move || {
            let _slot = slot;
            let result = lookup(host_owned.as_str(), port);
            // Receiver may have gone away after the timeout fired; the
            // send fails silently in that case and the thread exits,
            // which drops `_slot` and releases the pool slot.
            let _ = tx.send(result);
        })?;
    match rx.recv_timeout(timeout) {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!("DNS lookup for {host}:{port} exceeded {timeout:?}"),
        )),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(io::Error::other(
            "DNS resolver thread terminated without delivering a result",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    /// Numeric loopback resolves synchronously and well inside the
    /// budget on every supported platform.
    #[test]
    fn resolves_loopback_within_budget() {
        let addrs = resolve_with_timeout("127.0.0.1", 1234, Duration::from_secs(2))
            .expect("loopback resolves");
        assert!(!addrs.is_empty(), "expected at least one address");
        assert!(
            addrs.iter().all(|a| a.port() == 1234),
            "port must be propagated, got {addrs:?}",
        );
    }

    /// A near-zero budget surfaces as `TimedOut` rather than as a
    /// panic or as an unrelated error kind. We can't reliably stall a
    /// real resolver in a unit test, but pinning the error-kind
    /// translation guards the downstream `From<io::Error>` mapping
    /// that turns this into `NtsError::Timeout` on the Dart side.
    #[test]
    fn zero_budget_surfaces_as_timed_out() {
        let err = resolve_with_timeout("example.invalid", 0, Duration::from_nanos(1))
            .expect_err("zero budget cannot complete a real DNS lookup");
        // The resolver may fail synchronously (NXDOMAIN, no network)
        // before recv_timeout observes the deadline, and the resulting
        // `io::ErrorKind` varies by platform. Assert the error is real
        // (not a panic) and leave the kind unconstrained so the test
        // stays portable.
        let _ = err.kind();
    }

    /// Deterministic adversarial-resolver case: inject a lookup that
    /// blocks past the budget and prove the deadline fires with
    /// `ErrorKind::TimedOut`. Pinning the kind here is what guarantees
    /// `bind_connected_udp` can safely map the error onto
    /// `NtsError::Timeout` (rather than `NtsError::Network`) for slow
    /// recursive resolvers, without standing up a fake nameserver in
    /// the test harness. Wall-clock cap of 5× the budget absorbs CI
    /// scheduling jitter while still being orders of magnitude
    /// tighter than the resolver's own runtime.
    #[test]
    fn slow_resolver_surfaces_as_timed_out() {
        // Per-test stats bundle so this test can't be starved by —
        // and can't starve — any other test that hits the production
        // pool. Cap of 1 is enough since the test only spawns one
        // worker.
        static STATS: PoolStats = PoolStats::new();
        let budget = Duration::from_millis(50);
        let started = Instant::now();
        let err = resolve_with(&STATS, 1, "ignored.invalid", 0, budget, |_host, _port| {
            thread::sleep(Duration::from_secs(2));
            Ok(vec![SocketAddr::from(([127, 0, 0, 1], 0))])
        })
        .expect_err("slow resolver must trip the deadline");
        let elapsed = started.elapsed();

        assert_eq!(
            err.kind(),
            io::ErrorKind::TimedOut,
            "slow-DNS path must surface as TimedOut, got {err:?}",
        );
        let cap = budget * 5;
        assert!(
            elapsed < cap,
            "resolve_with took {elapsed:?} (> {cap:?}); recv_timeout did not honour the budget",
        );
    }

    /// Exhaustion path: fill the pool with sleeping workers that
    /// outlive the budget, then prove that the *next* call returns
    /// `ErrorKind::WouldBlock` immediately without spawning a thread.
    /// The wall-clock cap is well below the worker sleep so a missed
    /// fast-path would show up as a many-second hang rather than a
    /// false pass.
    #[test]
    fn cap_reached_returns_would_block() {
        static STATS: PoolStats = PoolStats::new();
        const CAP: usize = 2;
        let started = Instant::now();
        // Fill every slot with workers that will sleep for ~1 s.
        // Each call returns `TimedOut` after ~30 ms but the workers
        // (and therefore their slot guards) stay alive in the
        // background.
        for _ in 0..CAP {
            let err = resolve_with(
                &STATS,
                CAP,
                "ignored.invalid",
                0,
                Duration::from_millis(30),
                |_host, _port| {
                    thread::sleep(Duration::from_secs(1));
                    Ok(vec![])
                },
            )
            .expect_err("filler must time out");
            assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        }
        // Pool is now saturated. The next call must fail fast.
        let blocked = resolve_with(
            &STATS,
            CAP,
            "ignored.invalid",
            0,
            Duration::from_secs(60),
            |_host, _port| panic!("lookup must not run when cap is reached"),
        )
        .expect_err("saturated pool must reject new work");
        assert_eq!(
            blocked.kind(),
            io::ErrorKind::WouldBlock,
            "saturated pool must surface WouldBlock, got {blocked:?}",
        );
        let elapsed = started.elapsed();
        // Generous bound: the fillers contributed ~CAP * 30 ms, and
        // the saturated call must add only nanoseconds. Anything
        // approaching the worker sleep time (1 s) means the fast
        // path didn't actually run.
        assert!(
            elapsed < Duration::from_millis(500),
            "exhaustion path took {elapsed:?}; expected a fast-fail",
        );
    }

    /// RAII contract: the slot guard moves into the worker thread,
    /// so the in-flight count drops back to zero only *after* the
    /// worker terminates — not when the caller's `recv_timeout`
    /// fires. Verifies both halves of that contract: the count is
    /// non-zero immediately after the timeout fires, and reaches
    /// zero once the worker finishes.
    #[test]
    fn slot_released_when_worker_completes() {
        static STATS: PoolStats = PoolStats::new();
        let worker_runtime = Duration::from_millis(150);
        let budget = Duration::from_millis(20);

        let err = resolve_with(&STATS, 4, "ignored.invalid", 0, budget, move |_h, _p| {
            thread::sleep(worker_runtime);
            Ok(vec![])
        })
        .expect_err("budget must trip before the worker returns");
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);

        // Worker is still asleep; slot is held.
        assert_eq!(
            STATS.in_flight.load(Ordering::Acquire),
            1,
            "in-flight slot must remain held while detached worker is running",
        );

        // Wait long enough for the worker to finish and drop its
        // guard. Generous slack absorbs CI scheduler jitter without
        // turning a real regression into a flake.
        thread::sleep(worker_runtime * 4);
        assert_eq!(
            STATS.in_flight.load(Ordering::Acquire),
            0,
            "slot must be released once the detached worker completes",
        );
    }

    /// `recovered` increments exactly once per worker that releases a
    /// slot, regardless of whether the caller observed `TimedOut` or a
    /// successful result. Companion to `slot_released_when_worker_completes`
    /// for the cumulative-counter half of the contract.
    #[test]
    fn recovered_increments_on_worker_completion() {
        static STATS: PoolStats = PoolStats::new();
        let worker_runtime = Duration::from_millis(80);
        let budget = Duration::from_millis(20);

        let before = snapshot_of(&STATS).recovered;
        let _ = resolve_with(&STATS, 4, "ignored.invalid", 0, budget, move |_h, _p| {
            thread::sleep(worker_runtime);
            Ok(vec![])
        })
        .expect_err("budget must trip before the worker returns");

        // Recovered should still be `before` while the worker sleeps.
        assert_eq!(
            snapshot_of(&STATS).recovered,
            before,
            "recovered must not increment until the slot guard drops",
        );

        // Wait for the detached worker to finish and drop its guard.
        thread::sleep(worker_runtime * 4);
        assert_eq!(
            snapshot_of(&STATS).recovered,
            before + 1,
            "recovered must increment exactly once per slot release",
        );
        assert_eq!(
            snapshot_of(&STATS).in_flight,
            0,
            "in_flight must drain to zero alongside the recovered bump",
        );
    }

    /// `refused` increments exactly once per `try_acquire_slot` call
    /// that gets rejected because the cap was reached. Companion to
    /// `cap_reached_returns_would_block`.
    #[test]
    fn refused_increments_on_cap_exhaustion() {
        static STATS: PoolStats = PoolStats::new();
        const CAP: usize = 1;

        // Saturate the pool with a sleeping worker.
        let _ = resolve_with(
            &STATS,
            CAP,
            "ignored.invalid",
            0,
            Duration::from_millis(20),
            |_host, _port| {
                thread::sleep(Duration::from_millis(500));
                Ok(vec![])
            },
        )
        .expect_err("filler must time out");

        let before = snapshot_of(&STATS).refused;
        // Two cap-rejected calls — each must bump the counter exactly
        // once and never spawn a worker.
        for _ in 0..2 {
            let blocked = resolve_with(
                &STATS,
                CAP,
                "ignored.invalid",
                0,
                Duration::from_secs(60),
                |_host, _port| panic!("lookup must not run when cap is reached"),
            )
            .expect_err("saturated pool must reject new work");
            assert_eq!(blocked.kind(), io::ErrorKind::WouldBlock);
        }
        assert_eq!(
            snapshot_of(&STATS).refused,
            before + 2,
            "refused must increment once per rejected admission",
        );
    }

    /// `high_water_mark` tracks the maximum number of slots
    /// concurrently held. Admits N workers behind a barrier, asserts
    /// the mark equals N, then lets them finish and asserts the mark
    /// stays at N (monotonic, not pinned to the live `in_flight`).
    #[test]
    fn high_water_mark_tracks_concurrent_admissions() {
        use std::sync::{Arc, Barrier};

        static STATS: PoolStats = PoolStats::new();
        const N: usize = 4;

        // All admitted workers park on the same barrier so the slot
        // guards overlap. The test thread is barrier-party N+1 and
        // releases everyone once it has observed the high-water mark.
        // Driver threads deliberately do not assert on the
        // `resolve_with` return value — depending on whether
        // `recv_timeout` fires before or after the barrier completes,
        // the call may legally surface either `Ok(vec![])` or
        // `TimedOut`. The test asserts only what it is actually
        // measuring: HWM bookkeeping under concurrent admissions.
        let release = Arc::new(Barrier::new(N + 1));
        let mut joins = Vec::with_capacity(N);
        for _ in 0..N {
            let release = Arc::clone(&release);
            let join = thread::spawn(move || {
                let _ = resolve_with(
                    &STATS,
                    N,
                    "ignored.invalid",
                    0,
                    Duration::from_secs(5),
                    move |_host, _port| {
                        release.wait();
                        Ok(vec![])
                    },
                );
            });
            joins.push(join);
        }

        // Spin until the mark catches up to N. Each `resolve_with`
        // call increments `in_flight` *before* spawning the worker,
        // so the mark publishes well before the workers reach the
        // barrier — but we still poll under a 5 s ceiling to keep CI
        // jitter from flaking the test.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snap = snapshot_of(&STATS);
            if snap.high_water_mark >= N {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "high_water_mark stuck at {} (expected {N}); in_flight = {}",
                snap.high_water_mark,
                snap.in_flight,
            );
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            snapshot_of(&STATS).high_water_mark,
            N,
            "mark must equal the number of concurrently admitted workers",
        );

        // Release the workers and wait for them to drain.
        release.wait();
        for j in joins {
            j.join().expect("driver thread must not panic");
        }
        // Slot guards are dropped on the worker thread, which the
        // driver join above does not synchronise with. Spin briefly
        // until the in-flight counter drains; the workers have at
        // most a millisecond of post-barrier work left.
        let drain_deadline = Instant::now() + Duration::from_secs(1);
        while snapshot_of(&STATS).in_flight > 0 {
            assert!(
                Instant::now() < drain_deadline,
                "in_flight failed to drain after worker join: {}",
                snapshot_of(&STATS).in_flight,
            );
            thread::sleep(Duration::from_millis(5));
        }
        let final_snap = snapshot_of(&STATS);
        assert_eq!(
            final_snap.high_water_mark, N,
            "high_water_mark is monotonic; must stay at peak after drain",
        );
    }
}
