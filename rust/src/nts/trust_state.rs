//! Process-global trust-anchor diagnostic state.
//!
//! Records six observables that callers cannot recover from a
//! per-query [`crate::api::nts::NtsTimeSample`] alone:
//!
//! 1. The trust backend the *default singleton* [`crate::api::nts::NtsClient`]
//!    most recently resolved to. Custom-client callers read the
//!    per-handshake `trust_backend` field on `NtsTimeSample` /
//!    `NtsWarmCookiesOutcome` for accurate per-client attribution; this
//!    pointer exists for the singleton-path callers exposed via
//!    [`crate::api::nts::nts_query`] / [`crate::api::nts::nts_warm_cookies`]
//!    who never construct an `NtsClient` themselves. The pointer is an
//!    overwrite-on-store event marker, not a steady-state signal: a
//!    failed `build_with_native_verifier` later in the process latches
//!    `WebpkiRoots` permanently until the next `Platform` success, so
//!    consumers that want trend visibility should read the three
//!    cumulative counters in (2) rather than this field.
//!
//! 2. Three cumulative counters — one per [`InternalTrustBackend`]
//!    variant — bumped on every `record_default_backend` call. A
//!    dashboard can render `"P platform / H hybrid / W webpki of
//!    P+H+W total singleton handshakes"` without losing history when
//!    one backend transiently overrides another. The per-counter
//!    monotonicity contract matches the hybrid-fallback counter in
//!    (5); the three counters never decrease and never reset within
//!    a process lifetime.
//!
//! 3. Whether `Java_com_nllewellyn_nts_PlatformInit_nativeInit` has been
//!    invoked at least once and reported success on Android. The flag
//!    only flips false → true; once set it stays set for the rest of
//!    the process lifetime, matching the latched `OnceCell` semantics
//!    of `rustls_platform_verifier::android::init_with_env`.
//!
//! 4. (Reserved — see (5) for the Android-fallback counter.)
//!
//! 5. Cumulative count of TLS chains the Android
//!    `crate::nts::hybrid_verifier::HybridVerifier` (Android-only;
//!    intra-doc link omitted to keep rustdoc warning-free on
//!    non-Android targets) has accepted via its `webpki-roots`
//!    fallback path since process start. Bumped by every
//!    `verify_server_cert` call that overrides a platform verdict;
//!    never reset.
//!
//! All counters and the platform-init flag use atomic `Relaxed`
//! loads/stores: the snapshot returned by
//! [`crate::api::nts::nts_trust_status`] is intended for human /
//! dashboard consumption, not for cross-thread synchronisation.
//! Per-counter monotonicity holds (the platform-init flag never
//! re-clears, every cumulative counter never decreases), but
//! cross-counter invariants within a single snapshot do not — e.g.
//! the snapshot can observe a hybrid-fallback bump that happened
//! slightly after the default-backend store the same handshake
//! produced, or one of the three per-backend counters can be observed
//! to have bumped while `default_backend` still reads its prior value.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};

const BACKEND_UNSET: u8 = 0;
const BACKEND_PLATFORM: u8 = 1;
const BACKEND_PLATFORM_WITH_HYBRID_FALLBACK: u8 = 2;
const BACKEND_WEBPKI_ROOTS: u8 = 3;

/// Local mirror of [`crate::api::nts::TrustBackend`] used only as the
/// argument to [`ProcessTrustState::record_default_backend`]. The
/// public enum lives in `api::nts` so it can be FRB-mirrored into
/// Dart; this enum exists in the protocol-internal `nts` module so
/// the trust-state recording path does not introduce a circular
/// dependency on the public API surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum InternalTrustBackend {
    Platform,
    PlatformWithHybridFallback,
    WebpkiRoots,
}

/// Snapshot returned by [`ProcessTrustState::snapshot`]. Mapped into
/// [`crate::api::nts::NtsTrustStatus`] by the public-API layer, which
/// owns the `Option<TrustBackend>` translation for the unset state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TrustStateSnapshot {
    pub(crate) default_backend: Option<InternalTrustBackend>,
    pub(crate) default_backend_platform_count: u64,
    pub(crate) default_backend_hybrid_count: u64,
    pub(crate) default_backend_webpki_count: u64,
    pub(crate) android_platform_init_succeeded: bool,
    pub(crate) android_hybrid_fallback_count: u64,
}

pub(crate) struct ProcessTrustState {
    default_backend: AtomicU8,
    default_backend_platform_count: AtomicU64,
    default_backend_hybrid_count: AtomicU64,
    default_backend_webpki_count: AtomicU64,
    android_platform_init_succeeded: AtomicBool,
    android_hybrid_fallback_count: AtomicU64,
}

impl ProcessTrustState {
    const fn new() -> Self {
        Self {
            default_backend: AtomicU8::new(BACKEND_UNSET),
            default_backend_platform_count: AtomicU64::new(0),
            default_backend_hybrid_count: AtomicU64::new(0),
            default_backend_webpki_count: AtomicU64::new(0),
            android_platform_init_succeeded: AtomicBool::new(false),
            android_hybrid_fallback_count: AtomicU64::new(0),
        }
    }

    /// Record the trust backend resolved by the *default singleton*
    /// `NtsClient`'s most recent handshake. Called from the public-API
    /// `nts_query_inner` / `nts_warm_cookies_inner` paths only when
    /// the calling client is the process-wide default; custom-client
    /// handshakes do not touch these counters so a multi-client
    /// deployment can distinguish singleton vs non-singleton attribution.
    ///
    /// Two writes happen in lock-step:
    ///
    /// 1. The `default_backend` pointer overwrites to the new variant,
    ///    so a snapshot taken after this call reads `Some(b)` (until
    ///    the next call to this method).
    /// 2. The matching per-backend counter is bumped by one, giving
    ///    callers a cumulative trend signal independent of the
    ///    overwrite-on-store pointer.
    ///
    /// Both writes use `Relaxed` ordering — they are not synchronised
    /// against each other, so a concurrent snapshot may observe the
    /// counter bump before the pointer flip or vice versa. The
    /// cross-counter weak-ordering caveat documented on the module
    /// docstring applies.
    pub(crate) fn record_default_backend(&self, b: InternalTrustBackend) {
        let (v, counter) = match b {
            InternalTrustBackend::Platform => {
                (BACKEND_PLATFORM, &self.default_backend_platform_count)
            }
            InternalTrustBackend::PlatformWithHybridFallback => (
                BACKEND_PLATFORM_WITH_HYBRID_FALLBACK,
                &self.default_backend_hybrid_count,
            ),
            InternalTrustBackend::WebpkiRoots => {
                (BACKEND_WEBPKI_ROOTS, &self.default_backend_webpki_count)
            }
        };
        self.default_backend.store(v, Ordering::Relaxed);
        counter.fetch_add(1, Ordering::Relaxed);
    }

    /// Latch the Android JNI bootstrap flag. Idempotent; the flag
    /// only ever flips false → true so a second call after a
    /// successful first call is a no-op store. The
    /// `Java_com_nllewellyn_nts_PlatformInit_nativeInit` JNI symbol
    /// calls this exactly once per successful
    /// `rustls_platform_verifier::android::init_with_env` call.
    pub(crate) fn record_android_init_success(&self) {
        self.android_platform_init_succeeded
            .store(true, Ordering::Relaxed);
    }

    /// Bump the Android hybrid-verifier fallback counter. Called from
    /// `HybridVerifier::verify_server_cert` every time the
    /// `webpki-roots` fallback overrides a platform verdict.
    pub(crate) fn bump_hybrid_fallback(&self) {
        self.android_hybrid_fallback_count
            .fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn snapshot(&self) -> TrustStateSnapshot {
        let default_backend = match self.default_backend.load(Ordering::Relaxed) {
            BACKEND_PLATFORM => Some(InternalTrustBackend::Platform),
            BACKEND_PLATFORM_WITH_HYBRID_FALLBACK => {
                Some(InternalTrustBackend::PlatformWithHybridFallback)
            }
            BACKEND_WEBPKI_ROOTS => Some(InternalTrustBackend::WebpkiRoots),
            _ => None,
        };
        TrustStateSnapshot {
            default_backend,
            default_backend_platform_count: self
                .default_backend_platform_count
                .load(Ordering::Relaxed),
            default_backend_hybrid_count: self.default_backend_hybrid_count.load(Ordering::Relaxed),
            default_backend_webpki_count: self.default_backend_webpki_count.load(Ordering::Relaxed),
            android_platform_init_succeeded: self
                .android_platform_init_succeeded
                .load(Ordering::Relaxed),
            android_hybrid_fallback_count: self
                .android_hybrid_fallback_count
                .load(Ordering::Relaxed),
        }
    }
}

pub(crate) static TRUST_STATE: ProcessTrustState = ProcessTrustState::new();

#[cfg(test)]
mod tests {
    use super::*;

    // Every test here constructs a fresh `ProcessTrustState` via the
    // `const fn new()` ctor so the assertions are not coupled to the
    // process-global `TRUST_STATE` singleton's history. Tests that
    // touched the singleton would interfere with each other and with
    // any concurrently-running test that exercises the public API
    // path.

    #[test]
    fn snapshot_is_unset_after_construction() {
        let state = ProcessTrustState::new();
        let snap = state.snapshot();
        assert_eq!(snap.default_backend, None);
        assert_eq!(snap.default_backend_platform_count, 0);
        assert_eq!(snap.default_backend_hybrid_count, 0);
        assert_eq!(snap.default_backend_webpki_count, 0);
        assert!(!snap.android_platform_init_succeeded);
        assert_eq!(snap.android_hybrid_fallback_count, 0);
    }

    #[test]
    fn record_default_backend_round_trips_each_variant() {
        for variant in [
            InternalTrustBackend::Platform,
            InternalTrustBackend::PlatformWithHybridFallback,
            InternalTrustBackend::WebpkiRoots,
        ] {
            let state = ProcessTrustState::new();
            state.record_default_backend(variant);
            assert_eq!(state.snapshot().default_backend, Some(variant));
        }
    }

    #[test]
    fn record_default_backend_overwrites_previous_value() {
        let state = ProcessTrustState::new();
        state.record_default_backend(InternalTrustBackend::Platform);
        state.record_default_backend(InternalTrustBackend::WebpkiRoots);
        assert_eq!(
            state.snapshot().default_backend,
            Some(InternalTrustBackend::WebpkiRoots),
            "the most recent record_default_backend wins"
        );
    }

    /// Each call to `record_default_backend` bumps exactly the counter
    /// matching the variant being stored, and never any of the other
    /// two. This is the trend-visibility guarantee documented on
    /// `NtsTrustStatus::default_backend_*_count`: a dashboard reading
    /// the three numbers can attribute every singleton handshake to
    /// the backend that resolved it, even after subsequent handshakes
    /// overwrite the `default_backend` pointer.
    #[test]
    fn record_default_backend_bumps_only_the_matching_counter() {
        for (variant, expected_platform, expected_hybrid, expected_webpki) in [
            (InternalTrustBackend::Platform, 1u64, 0u64, 0u64),
            (InternalTrustBackend::PlatformWithHybridFallback, 0, 1, 0),
            (InternalTrustBackend::WebpkiRoots, 0, 0, 1),
        ] {
            let state = ProcessTrustState::new();
            state.record_default_backend(variant);
            let snap = state.snapshot();
            assert_eq!(
                snap.default_backend_platform_count, expected_platform,
                "platform counter after recording {variant:?}"
            );
            assert_eq!(
                snap.default_backend_hybrid_count, expected_hybrid,
                "hybrid counter after recording {variant:?}"
            );
            assert_eq!(
                snap.default_backend_webpki_count, expected_webpki,
                "webpki counter after recording {variant:?}"
            );
        }
    }

    /// The per-backend counters are cumulative and monotonic: repeated
    /// stores of the same variant keep incrementing, and switching
    /// variants does not reset any counter. The sum across the three
    /// equals the total number of `record_default_backend` calls.
    #[test]
    fn record_default_backend_counters_are_cumulative_and_monotonic() {
        let state = ProcessTrustState::new();
        state.record_default_backend(InternalTrustBackend::Platform);
        state.record_default_backend(InternalTrustBackend::Platform);
        state.record_default_backend(InternalTrustBackend::WebpkiRoots);
        state.record_default_backend(InternalTrustBackend::PlatformWithHybridFallback);
        state.record_default_backend(InternalTrustBackend::WebpkiRoots);
        state.record_default_backend(InternalTrustBackend::WebpkiRoots);
        let snap = state.snapshot();
        assert_eq!(snap.default_backend_platform_count, 2);
        assert_eq!(snap.default_backend_hybrid_count, 1);
        assert_eq!(snap.default_backend_webpki_count, 3);
        assert_eq!(
            snap.default_backend_platform_count
                + snap.default_backend_hybrid_count
                + snap.default_backend_webpki_count,
            6,
            "the three counters partition every record_default_backend call"
        );
        // The overwrite-on-store pointer reflects only the most
        // recent store, regardless of how the counters partition the
        // history that preceded it.
        assert_eq!(
            snap.default_backend,
            Some(InternalTrustBackend::WebpkiRoots),
        );
    }

    #[test]
    fn record_android_init_success_is_idempotent_and_latches_true() {
        let state = ProcessTrustState::new();
        assert!(!state.snapshot().android_platform_init_succeeded);
        state.record_android_init_success();
        assert!(state.snapshot().android_platform_init_succeeded);
        // The second call is a redundant true store; the snapshot
        // continues to read true rather than toggling back to false.
        state.record_android_init_success();
        assert!(state.snapshot().android_platform_init_succeeded);
    }

    #[test]
    fn bump_hybrid_fallback_increments_monotonically() {
        let state = ProcessTrustState::new();
        assert_eq!(state.snapshot().android_hybrid_fallback_count, 0);
        state.bump_hybrid_fallback();
        assert_eq!(state.snapshot().android_hybrid_fallback_count, 1);
        for _ in 0..4 {
            state.bump_hybrid_fallback();
        }
        assert_eq!(state.snapshot().android_hybrid_fallback_count, 5);
    }

    /// Every counter in the snapshot is independent; touching one
    /// must not bleed into the others. Cross-counter independence is
    /// the property the snapshot accessor's parallel-load contract
    /// relies on so consumers can read each observable without an
    /// upstream lock.
    #[test]
    fn snapshot_carries_every_independent_counter() {
        let state = ProcessTrustState::new();
        // Hybrid-fallback variant on the default-backend pointer
        // bumps `default_backend_hybrid_count`; the other two
        // per-backend counters must stay zero, and the Android
        // hybrid-verifier counter (5) is touched independently below.
        state.record_default_backend(InternalTrustBackend::PlatformWithHybridFallback);
        state.record_android_init_success();
        state.bump_hybrid_fallback();
        state.bump_hybrid_fallback();
        let snap = state.snapshot();
        assert_eq!(
            snap.default_backend,
            Some(InternalTrustBackend::PlatformWithHybridFallback)
        );
        assert_eq!(snap.default_backend_platform_count, 0);
        assert_eq!(snap.default_backend_hybrid_count, 1);
        assert_eq!(snap.default_backend_webpki_count, 0);
        assert!(snap.android_platform_init_succeeded);
        assert_eq!(snap.android_hybrid_fallback_count, 2);
    }
}
